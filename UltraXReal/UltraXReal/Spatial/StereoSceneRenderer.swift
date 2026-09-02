import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - GPU data (layouts mirror StereoShaders.metal)

struct SceneVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
}

struct LineVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

struct InstanceData {
    var model: simd_float4x4
    var color: SIMD4<Float>
}

struct EyeUniforms {
    var viewProjection: simd_float4x4
    var lightDir: SIMD4<Float>
}

/// One chair standing on the floor: its mesh range in the shared vertex buffer and placement.
private struct ChairPlacement {
    var vertexStart: Int
    var vertexCount: Int
    var model: simd_float4x4
    var color: SIMD4<Float>
}

/// Stereo demo: the viewer stands in the middle of a ring of twelve different chairs.
/// Renders the scene twice (left/right eye) side by side into a fullscreen window
/// on the glasses. In SBS mode the glasses show each half to one eye, giving real depth.
final class StereoSceneRenderer: NSObject, ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var fps: Int = 0

    /// 2 when the glasses are in side-by-side mode, 1 when falling back to mono.
    private(set) var eyeCount = 1

    /// Interpupillary distance, metres.
    var ipd: Float = 0.063
    /// XReal Air: ~46° diagonal per eye at 16:9 ≈ 23° vertical.
    var verticalFOV: Float = 23.0 * .pi / 180.0
    /// Signs applied to the head angles from the IMU. Flip one if that axis feels inverted.
    var yawSign: Float = -1
    var pitchSign: Float = 1
    var rollSign: Float = 1
    /// Eye height above the floor, metres.
    var eyeHeight: Float = 1.2

    private weak var imuService: XRealIMUService?

    // Metal
    private var metalDevice: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var scenePipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!

    // Geometry
    private var chairVertexBuffer: MTLBuffer?
    private var chairs: [ChairPlacement] = []
    private var gridVertexBuffer: MTLBuffer!
    private var gridVertexCount = 0

    // Output
    private var outputWindow: NSWindow?
    private var metalView: MTKView!
    private var screenObserver: NSObjectProtocol?
    private var hiddenBecauseNoGlasses = false

    private var frameCount = 0
    private var fpsTimer: Timer?

    init(imuService: XRealIMUService) {
        self.imuService = imuService
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - Public

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        guard setupMetal() else {
            print("[Stereo] Failed to set up Metal")
            return false
        }
        buildScene()

        guard setupOutputWindow() else {
            print("[Stereo] XReal Air display not found")
            return false
        }

        isRunning = true
        startFPSCounter()
        return true
    }

    func stop() {
        isRunning = false
        fpsTimer?.invalidate()
        fpsTimer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        metalView?.isPaused = true
        outputWindow?.orderOut(nil)
        outputWindow = nil
        metalView = nil
    }

    func recenter() {
        imuService?.recenter()
    }

    // MARK: - Setup

    private func setupMetal() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return false }
        metalDevice = device
        commandQueue = queue

        func makePipeline(vertex: String, fragment: String) -> MTLRenderPipelineState? {
            guard let vertexFn = library.makeFunction(name: vertex),
                  let fragmentFn = library.makeFunction(name: fragment) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let scene = makePipeline(vertex: "stereoSceneVertex", fragment: "stereoSceneFragment"),
              let line = makePipeline(vertex: "stereoLineVertex", fragment: "stereoLineFragment") else {
            print("[Stereo] Failed to load shaders")
            return false
        }
        scenePipeline = scene
        linePipeline = line

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        return true
    }

    private func setupOutputWindow() -> Bool {
        guard let screen = findXRealScreen() else { return false }

        let pixelWidth = screen.frame.width * screen.backingScaleFactor
        eyeCount = pixelWidth >= 3000 ? 2 : 1
        print("[Stereo] Output \(Int(pixelWidth))px wide, \(eyeCount == 2 ? "side-by-side stereo" : "mono fallback")")

        metalView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: metalDevice)
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 120
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)
        metalView.clearDepth = 1.0
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        // With `screen:` the content rect is relative to that screen's origin.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.contentView = metalView
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        outputWindow = window

        // macOS moves windows of a vanished display onto the main display. Never let that show.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncToGlassesScreen()
        }
        return true
    }

    private func syncToGlassesScreen() {
        guard let window = outputWindow else { return }
        guard let screen = findXRealScreen() else {
            if !hiddenBecauseNoGlasses {
                hiddenBecauseNoGlasses = true
                metalView?.isPaused = true
                window.orderOut(nil)
                print("[Stereo] Glasses display gone, hiding")
            }
            return
        }
        if hiddenBecauseNoGlasses || window.screen != screen {
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            metalView?.isPaused = false
            hiddenBecauseNoGlasses = false
            print("[Stereo] Back on the glasses display")
        }
    }

    private func findXRealScreen() -> NSScreen? {
        guard let displayID = DisplayMirrorHelper.findXRealDisplay() else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    // MARK: - Scene

    private func buildScene() {
        let floorY = -eyeHeight
        buildChairs(floorY: floorY)
        buildFloorGrid(floorY: floorY)
    }

    private func buildChairs(floorY: Float) {
        let palette: [SIMD4<Float>] = [
            SIMD4(0.90, 0.35, 0.30, 1), SIMD4(0.30, 0.70, 0.95, 1), SIMD4(0.95, 0.80, 0.25, 1),
            SIMD4(0.40, 0.85, 0.45, 1), SIMD4(0.80, 0.45, 0.90, 1), SIMD4(0.95, 0.60, 0.30, 1),
            SIMD4(0.55, 0.85, 0.90, 1), SIMD4(0.85, 0.75, 0.60, 1), SIMD4(0.60, 0.40, 0.25, 1),
            SIMD4(0.35, 0.50, 0.80, 1), SIMD4(0.90, 0.90, 0.90, 1), SIMD4(0.75, 0.25, 0.45, 1),
        ]

        // Twelve different chairs: (seat width, seat depth, seat height, back height, back style, arms, legs)
        // back style: 0 = none (stool), 1 = solid, 2 = slats, 3 = tall solid
        // legs: 0 = four legs, 1 = pedestal
        let variants: [(w: Float, d: Float, h: Float, back: Float, style: Int, arms: Bool, legs: Int)] = [
            (0.45, 0.45, 0.45, 0.50, 1, false, 0),   // plain kitchen chair
            (0.50, 0.50, 0.42, 0.60, 2, true, 0),    // slatted armchair
            (0.35, 0.35, 0.70, 0.00, 0, false, 0),   // bar stool
            (0.55, 0.55, 0.40, 0.75, 3, true, 1),    // office chair on a pedestal
            (0.42, 0.42, 0.46, 0.45, 2, false, 0),   // slatted dining chair
            (0.60, 0.55, 0.38, 0.55, 1, true, 0),    // wide lounge chair
            (0.40, 0.40, 0.30, 0.00, 0, false, 0),   // low stool
            (0.45, 0.45, 0.48, 0.90, 3, false, 0),   // high-back chair
            (0.48, 0.45, 0.44, 0.50, 1, true, 0),    // chair with arms
            (0.38, 0.38, 0.45, 0.40, 2, false, 1),   // slatted chair on a pedestal
            (0.52, 0.50, 0.35, 0.65, 1, true, 1),    // low armchair on a pedestal
            (0.44, 0.44, 0.47, 0.55, 2, false, 0),   // tall slatted chair
        ]

        var vertices: [SceneVertex] = []
        let count = variants.count
        for (i, v) in variants.enumerated() {
            let startIndex = vertices.count
            let seatTop = v.h
            let seatThickness: Float = 0.05
            let halfW = v.w / 2
            let halfD = v.d / 2

            // Seat
            appendBox(center: SIMD3(0, seatTop - seatThickness / 2, 0),
                      size: SIMD3(v.w, seatThickness, v.d), into: &vertices)

            // Legs
            switch v.legs {
            case 1:
                appendBox(center: SIMD3(0, seatTop / 2, 0), size: SIMD3(0.06, seatTop, 0.06), into: &vertices)
                appendBox(center: SIMD3(0, 0.02, 0), size: SIMD3(v.w * 1.1, 0.04, v.d * 1.1), into: &vertices)
            default:
                let inset: Float = 0.04
                for x in [-(halfW - inset), halfW - inset] {
                    for z in [-(halfD - inset), halfD - inset] {
                        appendBox(center: SIMD3(x, (seatTop - seatThickness) / 2, z),
                                  size: SIMD3(0.04, seatTop - seatThickness, 0.04), into: &vertices)
                    }
                }
            }

            // Backrest (chair front is +Z, back is -Z)
            let backZ = -(halfD - 0.025)
            switch v.style {
            case 1, 3:
                appendBox(center: SIMD3(0, seatTop + v.back / 2, backZ),
                          size: SIMD3(v.w, v.back, 0.05), into: &vertices)
            case 2:
                // Two posts and three horizontal slats
                for x in [-(halfW - 0.03), halfW - 0.03] {
                    appendBox(center: SIMD3(x, seatTop + v.back / 2, backZ),
                              size: SIMD3(0.04, v.back, 0.04), into: &vertices)
                }
                for k in 0..<3 {
                    let y = seatTop + v.back * (0.3 + 0.3 * Float(k))
                    appendBox(center: SIMD3(0, y, backZ), size: SIMD3(v.w - 0.06, 0.06, 0.03), into: &vertices)
                }
            default:
                break
            }

            // Armrests
            if v.arms {
                let armH: Float = 0.22
                for x in [-(halfW - 0.02), halfW - 0.02] {
                    appendBox(center: SIMD3(x, seatTop + armH, 0), size: SIMD3(0.04, 0.03, v.d * 0.9), into: &vertices)
                    appendBox(center: SIMD3(x, seatTop + armH / 2, halfD - 0.05), size: SIMD3(0.03, armH, 0.03), into: &vertices)
                }
            }

            // Place on a ring around the viewer, facing the centre.
            let angle = Float(i) / Float(count) * 2 * .pi
            let radius: Float = 2.4 + 0.5 * Float(i % 3)
            let position = SIMD3<Float>(radius * sin(angle), floorY, -radius * cos(angle))
            let yaw = atan2(-position.x, -position.z)
            let model = translation(position) * rotationY(yaw)

            chairs.append(ChairPlacement(
                vertexStart: startIndex,
                vertexCount: vertices.count - startIndex,
                model: model,
                color: palette[i % palette.count]
            ))
        }
        chairVertexBuffer = metalDevice.makeBuffer(bytes: vertices,
                                                   length: MemoryLayout<SceneVertex>.stride * vertices.count)
    }

    /// Floor grid for orientation.
    private func buildFloorGrid(floorY: Float) {
        var lines: [LineVertex] = []
        let extent: Float = 8
        let dim = SIMD4<Float>(0.25, 0.28, 0.35, 1)
        let axis = SIMD4<Float>(0.45, 0.45, 0.55, 1)
        var i: Float = -extent
        while i <= extent {
            let c = i == 0 ? axis : dim
            lines.append(LineVertex(position: SIMD3(i, floorY, -extent), color: c))
            lines.append(LineVertex(position: SIMD3(i, floorY, extent), color: c))
            lines.append(LineVertex(position: SIMD3(-extent, floorY, i), color: c))
            lines.append(LineVertex(position: SIMD3(extent, floorY, i), color: c))
            i += 1
        }
        gridVertexCount = lines.count
        gridVertexBuffer = metalDevice.makeBuffer(bytes: lines,
                                                  length: MemoryLayout<LineVertex>.stride * lines.count)
    }

    private func appendBox(center: SIMD3<Float>, size: SIMD3<Float>, into vertices: inout [SceneVertex]) {
        let h = size / 2
        // (normal, u axis, v axis) per face
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        for (n, u, v) in faces {
            let faceCenter = center + n * h
            let du = u * h
            let dv = v * h
            let p0 = faceCenter - du - dv
            let p1 = faceCenter + du - dv
            let p2 = faceCenter + du + dv
            let p3 = faceCenter - du + dv
            for p in [p0, p1, p2, p0, p2, p3] {
                vertices.append(SceneVertex(position: p, normal: n))
            }
        }
    }

    // MARK: - Per-frame math

    /// World-to-camera rotation from the IMU head angles.
    /// IMU convention (see SpatialTracker): yaw about the up axis, pitch about the left axis.
    /// Graphics frame: x right, y up, z backward.
    private func headViewRotation() -> simd_float4x4 {
        let q = imuService?.relativeOrientation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let (yaw, pitch, roll) = eulerAngles(from: q)

        // Camera orientation: yaw about +Y, pitch about +X, roll about the forward axis (-Z).
        let camera = rotationY(yaw * yawSign) * rotationX(pitch * pitchSign) * rotationZ(-roll * rollSign)
        return camera.transpose
    }

    /// Yaw (about Z), pitch (about Y), roll (about X) of the IMU quaternion, ZYX convention.
    private func eulerAngles(from q: simd_quatf) -> (yaw: Float, pitch: Float, roll: Float) {
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real

        let sinyCosp = 2 * (w * z + x * y)
        let cosyCosp = 1 - 2 * (y * y + z * z)
        let yaw = atan2(sinyCosp, cosyCosp)

        let sinp = 2 * (w * y - z * x)
        let pitch = abs(sinp) >= 1 ? copysign(Float.pi / 2, sinp) : asin(sinp)

        let sinrCosp = 2 * (w * x + y * z)
        let cosrCosp = 1 - 2 * (x * x + y * y)
        let roll = atan2(sinrCosp, cosrCosp)

        return (yaw, pitch, roll)
    }

    private func eyeViewProjection(eye: Int, viewRotation: simd_float4x4, aspect: Float) -> simd_float4x4 {
        // Left eye sits at -ipd/2 in camera space, right eye at +ipd/2.
        let eyeX: Float = eyeCount == 2 ? (eye == 0 ? -ipd / 2 : ipd / 2) : 0
        let view = translation(SIMD3(-eyeX, 0, 0)) * viewRotation
        let projection = perspective(fovY: verticalFOV, aspect: aspect, near: 0.05, far: 100)
        return projection * view
    }

    private func startFPSCounter() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.frameCount
            self.frameCount = 0
        }
    }
}

// MARK: - MTKViewDelegate

extension StereoSceneRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard isRunning,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let viewRotation = headViewRotation()
        let fullWidth = Double(view.drawableSize.width)
        let fullHeight = Double(view.drawableSize.height)
        let eyeWidth = fullWidth / Double(eyeCount)
        let aspect = Float(eyeWidth / fullHeight)

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)

        for eye in 0..<eyeCount {
            encoder.setViewport(MTLViewport(originX: Double(eye) * eyeWidth, originY: 0,
                                            width: eyeWidth, height: fullHeight,
                                            znear: 0, zfar: 1))

            var uniforms = EyeUniforms(
                viewProjection: eyeViewProjection(eye: eye, viewRotation: viewRotation, aspect: aspect),
                lightDir: SIMD4(0.4, 1.0, 0.6, 0)
            )

            // Floor grid
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(gridVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<EyeUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)

            // Chairs
            if let chairVertexBuffer, !chairs.isEmpty {
                encoder.setRenderPipelineState(scenePipeline)
                encoder.setVertexBuffer(chairVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<EyeUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EyeUniforms>.stride, index: 2)
                for chair in chairs {
                    var instance = InstanceData(model: chair.model, color: chair.color)
                    encoder.setVertexBytes(&instance, length: MemoryLayout<InstanceData>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: chair.vertexStart, vertexCount: chair.vertexCount)
                }
            }

        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameCount += 1
    }
}

// MARK: - Matrix helpers

private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(t, 1)
    return m
}

private func scaling(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(s, s, s, 1))
}

private func rotationX(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(1, 0, 0, 0),
        SIMD4(0, c, -s, 0),
        SIMD4(0, s, c, 0),
        SIMD4(0, 0, 0, 1),
    ])
}

private func rotationZ(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(c, -s, 0, 0),
        SIMD4(s, c, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(0, 0, 0, 1),
    ])
}

private func rotationY(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(c, 0, s, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(-s, 0, c, 0),
        SIMD4(0, 0, 0, 1),
    ])
}

/// Right-handed perspective projection, Metal clip space (z in 0...1).
private func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY / 2)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1),
        SIMD4(0, 0, z * near, 0)
    ))
}
