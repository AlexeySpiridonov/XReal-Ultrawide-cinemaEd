import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - GPU data (layouts mirror StereoShaders.metal)

struct SceneVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

struct EyeUniforms {
    var viewProjection: simd_float4x4
    var inverseViewProjection: simd_float4x4
    var sunDir: SIMD4<Float>
    var cameraPos: SIMD4<Float>   // xyz eye, w time
    var params: SIMD4<Float>      // x ground height, y fog density
}

/// Deterministic random numbers so the monument looks the same every time.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ r: ClosedRange<Float>) -> Float { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
}

/// Stereo demo: the viewer stands in the middle of Stonehenge under a blue sky.
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
    /// Eye height above the ground, metres (standing).
    var eyeHeight: Float = 1.7
    /// Direction towards the sun.
    var sunDirection = simd_normalize(SIMD3<Float>(0.55, 0.62, 0.35))
    var fogDensity: Float = 0.0085

    private weak var imuService: XRealIMUService?

    // Metal
    private var metalDevice: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var skyPipeline: MTLRenderPipelineState!
    private var groundPipeline: MTLRenderPipelineState!
    private var stonePipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    private var noDepthState: MTLDepthStencilState!

    // Geometry (world space)
    private var stoneVertexBuffer: MTLBuffer!
    private var stoneVertexCount = 0
    private var groundVertexBuffer: MTLBuffer!
    private var groundVertexCount = 0

    // Output
    private var outputWindow: NSWindow?
    private var metalView: MTKView!
    private var screenObserver: NSObjectProtocol?
    private var hiddenBecauseNoGlasses = false

    private let startTime = CACurrentMediaTime()
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

        func makePipeline(vertex: String, fragment: String, blending: Bool = false) -> MTLRenderPipelineState? {
            guard let vertexFn = library.makeFunction(name: vertex),
                  let fragmentFn = library.makeFunction(name: fragment) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .zero
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let sky = makePipeline(vertex: "skyVertex", fragment: "skyFragment"),
              let ground = makePipeline(vertex: "sceneVertex", fragment: "groundFragment"),
              let stone = makePipeline(vertex: "sceneVertex", fragment: "stoneFragment"),
              let shadow = makePipeline(vertex: "sceneVertex", fragment: "shadowFragment", blending: true) else {
            print("[Stereo] Failed to load shaders")
            return false
        }
        skyPipeline = sky
        groundPipeline = ground
        stonePipeline = stone
        shadowPipeline = shadow

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        let noDepthDescriptor = MTLDepthStencilDescriptor()
        noDepthDescriptor.depthCompareFunction = .always
        noDepthDescriptor.isDepthWriteEnabled = false
        noDepthState = device.makeDepthStencilState(descriptor: noDepthDescriptor)

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
        metalView.clearColor = MTLClearColor(red: 0.72, green: 0.84, blue: 0.96, alpha: 1)
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

    // MARK: - Scene: Stonehenge

    /// Azimuth 0 points along -Z (where the viewer looks after recentering), clockwise positive.
    private func ringPoint(radius: Float, azimuthDegrees: Float) -> SIMD3<Float> {
        let a = azimuthDegrees * .pi / 180
        return SIMD3(radius * sin(a), 0, -radius * cos(a))
    }

    private func buildScene() {
        let ground = -eyeHeight
        var rng = SeededRandom(seed: 1136)
        var vertices: [SceneVertex] = []

        let sarsen = SIMD3<Float>(0.60, 0.57, 0.52)
        let blue = SIMD3<Float>(0.44, 0.46, 0.50)

        /// Standing stone: width along the ring tangent, thickness radially, height up.
        func standing(at position: SIMD3<Float>, yaw: Float, width: Float, thickness: Float, height: Float,
                      tint: SIMD3<Float>, tilt: Float = 0, sink: Float = 0.4) {
            let color = tint * rng.range(0.88...1.12)
            let model = translation(SIMD3(position.x, ground + height / 2 - sink / 2, position.z))
                * rotationY(yaw) * rotationX(tilt)
            appendStone(size: SIMD3(width, height + sink, thickness), model: model, color: color, taper: 0.10, rng: &rng, into: &vertices)
        }

        /// Fallen stone lying on the grass.
        func fallen(at position: SIMD3<Float>, yaw: Float, length: Float, width: Float, thickness: Float, tint: SIMD3<Float>) {
            let color = tint * rng.range(0.88...1.12)
            let model = translation(SIMD3(position.x, ground + thickness / 2 - 0.15, position.z)) * rotationY(yaw)
            appendStone(size: SIMD3(length, thickness, width), model: model, color: color, taper: 0.0, rng: &rng, into: &vertices)
        }

        func lintel(from a: SIMD3<Float>, to b: SIMD3<Float>, top: Float, thickness: Float, height: Float, tint: SIMD3<Float>) {
            let mid = (a + b) / 2
            let d = b - a
            let length = simd_length(d) + 0.6
            let yaw = atan2(d.z, d.x)
            let color = tint * rng.range(0.9...1.1)
            let model = translation(SIMD3(mid.x, ground + top + height / 2, mid.z)) * rotationY(-yaw)
            appendStone(size: SIMD3(length, height, thickness), model: model, color: color, taper: 0.03, rng: &rng, into: &vertices)
        }

        // --- Sarsen circle: 30 uprights, radius 16.5 m, about half still standing ---
        let sarsenRadius: Float = 16.5
        let sarsenHeight: Float = 4.1
        let standingSarsens: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 9, 10, 15, 20, 21, 22, 26, 27, 28, 29]
        let lintelSarsens: Set<Int> = [0, 1, 2, 3, 4, 5, 20, 21, 26, 27, 28, 29]
        let fallenSarsens: Set<Int> = [7, 11, 13, 24]
        var sarsenTop: [Int: SIMD3<Float>] = [:]
        for i in 0..<30 {
            let az = Float(i) * 12
            let p = ringPoint(radius: sarsenRadius, azimuthDegrees: az)
            if standingSarsens.contains(i) {
                let h = sarsenHeight + rng.range(-0.25...0.25)
                standing(at: p, yaw: -az * .pi / 180 + rng.range(-0.04...0.04), width: 2.1, thickness: 1.1,
                         height: h, tint: sarsen, tilt: rng.range(-0.02...0.02))
                sarsenTop[i] = SIMD3(p.x, h, p.z)
            } else if fallenSarsens.contains(i) {
                let q = ringPoint(radius: sarsenRadius - 1.8, azimuthDegrees: az + rng.range(-4...4))
                fallen(at: q, yaw: -az * .pi / 180 + rng.range(-0.5...0.5), length: 3.8, width: 2.0, thickness: 1.0, tint: sarsen)
            }
        }
        for i in 0..<30 where lintelSarsens.contains(i) {
            guard let a = sarsenTop[i], let b = sarsenTop[(i + 1) % 30] else { continue }
            lintel(from: SIMD3(a.x, 0, a.z), to: SIMD3(b.x, 0, b.z), top: min(a.y, b.y) - 0.05, thickness: 1.0, height: 0.8, tint: sarsen)
        }

        // --- Trilithon horseshoe: five pairs, tallest at the back, opening towards the viewer's front ---
        let trilithons: [(az: Float, radius: Float, height: Float)] = [
            (180, 6.8, 7.3), (-128, 7.6, 6.4), (128, 7.6, 6.4), (-66, 8.6, 6.0), (66, 8.6, 6.0),
        ]
        for t in trilithons {
            let center = ringPoint(radius: t.radius, azimuthDegrees: t.az)
            let a = t.az * .pi / 180
            let tangent = SIMD3<Float>(cos(a), 0, sin(a))
            let left = center - tangent * 1.35
            let right = center + tangent * 1.35
            standing(at: left, yaw: -a, width: 2.2, thickness: 1.3, height: t.height, tint: sarsen, tilt: rng.range(-0.015...0.015))
            standing(at: right, yaw: -a, width: 2.2, thickness: 1.3, height: t.height, tint: sarsen, tilt: rng.range(-0.015...0.015))
            lintel(from: left, to: right, top: t.height - 0.05, thickness: 1.4, height: 1.0, tint: sarsen)
        }

        // --- Bluestone circle (radius 12 m) and horseshoe (radius 5.2 m) ---
        for i in 0..<29 {
            guard rng.unit() > 0.3 else { continue }
            let az = Float(i) * (360.0 / 29.0) + rng.range(-3...3)
            let p = ringPoint(radius: 12.0 + rng.range(-0.3...0.3), azimuthDegrees: az)
            standing(at: p, yaw: -az * .pi / 180 + rng.range(-0.4...0.4), width: rng.range(0.8...1.2),
                     thickness: rng.range(0.5...0.7), height: rng.range(1.3...2.3), tint: blue, tilt: rng.range(-0.06...0.06))
        }
        for i in 0..<9 {
            let az: Float = 100 + Float(i) * 20
            let p = ringPoint(radius: 5.2, azimuthDegrees: az)
            standing(at: p, yaw: -az * .pi / 180 + rng.range(-0.2...0.2), width: rng.range(0.7...1.0),
                     thickness: rng.range(0.45...0.6), height: rng.range(1.6...2.5), tint: blue)
        }

        // --- Altar stone (lying at the back), slaughter stone and heel stone (outside the circle) ---
        fallen(at: ringPoint(radius: 2.4, azimuthDegrees: 180), yaw: 0.35, length: 4.8, width: 1.0, thickness: 0.5, tint: blue * 1.1)
        fallen(at: ringPoint(radius: 34, azimuthDegrees: 4), yaw: 0.1, length: 6.4, width: 2.0, thickness: 0.8, tint: sarsen)
        standing(at: ringPoint(radius: 78, azimuthDegrees: 2), yaw: 0.2, width: 2.4, thickness: 1.6, height: 4.7, tint: sarsen * 0.95, tilt: -0.25)
        // Station stones
        standing(at: ringPoint(radius: 42, azimuthDegrees: 52), yaw: 0.3, width: 1.2, thickness: 0.8, height: 1.3, tint: sarsen)
        standing(at: ringPoint(radius: 42, azimuthDegrees: 232), yaw: 0.9, width: 1.0, thickness: 0.7, height: 1.0, tint: sarsen)

        stoneVertexCount = vertices.count
        stoneVertexBuffer = metalDevice.makeBuffer(bytes: vertices, length: MemoryLayout<SceneVertex>.stride * vertices.count)

        // --- Ground: one large quad, everything else is done in the fragment shader ---
        let extent: Float = 600
        let up = SIMD3<Float>(0, 1, 0)
        let white = SIMD4<Float>(1, 1, 1, 1)
        let corners = [
            SIMD3<Float>(-extent, ground, -extent), SIMD3<Float>(extent, ground, -extent),
            SIMD3<Float>(extent, ground, extent), SIMD3<Float>(-extent, ground, extent),
        ]
        let groundVertices = [corners[0], corners[2], corners[1], corners[0], corners[3], corners[2]]
            .map { SceneVertex(position: $0, normal: up, color: white) }
        groundVertexCount = groundVertices.count
        groundVertexBuffer = metalDevice.makeBuffer(bytes: groundVertices, length: MemoryLayout<SceneVertex>.stride * groundVertices.count)
    }

    /// A rough stone block: a box with tapered top and jittered corners, baked into world space.
    private func appendStone(size: SIMD3<Float>, model: simd_float4x4, color: SIMD3<Float>, taper: Float,
                             rng: inout SeededRandom, into vertices: inout [SceneVertex]) {
        let h = size / 2
        // 8 corners: index bits x(1) y(2) z(4)
        var corners: [SIMD3<Float>] = []
        for i in 0..<8 {
            let sx: Float = (i & 1) == 0 ? -1 : 1
            let sy: Float = (i & 2) == 0 ? -1 : 1
            let sz: Float = (i & 4) == 0 ? -1 : 1
            let shrink: Float = sy > 0 ? (1 - taper) : 1
            var c = SIMD3(sx * h.x * shrink, sy * h.y, sz * h.z * shrink)
            c += SIMD3(rng.range(-0.05...0.05) * size.x, rng.range(-0.03...0.03) * size.y, rng.range(-0.06...0.06) * size.z)
            corners.append(c)
        }
        // Faces as corner indices (counter-clockwise seen from outside)
        let faces: [[Int]] = [
            [4, 5, 7, 6],  // +z
            [1, 0, 2, 3],  // -z
            [5, 1, 3, 7],  // +x
            [0, 4, 6, 2],  // -x
            [2, 6, 7, 3],  // +y (top)
            [0, 1, 5, 4],  // -y
        ]
        let rgba = SIMD4(color, 1)
        for face in faces {
            let p = face.map { (model * SIMD4(corners[$0], 1)).xyz }
            for tri in [[0, 1, 2], [0, 2, 3]] {
                let a = p[tri[0]], b = p[tri[1]], c = p[tri[2]]
                let n = simd_normalize(simd_cross(b - a, c - a))
                vertices.append(SceneVertex(position: a, normal: n, color: rgba))
                vertices.append(SceneVertex(position: b, normal: n, color: rgba))
                vertices.append(SceneVertex(position: c, normal: n, color: rgba))
            }
        }
    }

    // MARK: - Per-frame math

    /// World-to-camera rotation from the IMU head angles.
    private func headViewRotation() -> simd_float4x4 {
        let q = imuService?.relativeOrientation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let (yaw, pitch, roll) = eulerAngles(from: q)
        let camera = rotationY(yaw * yawSign) * rotationX(pitch * pitchSign) * rotationZ(-roll * rollSign)
        return camera.transpose
    }

    /// Yaw (about Z), pitch (about Y), roll (about X) of the IMU quaternion, ZYX convention.
    private func eulerAngles(from q: simd_quatf) -> (yaw: Float, pitch: Float, roll: Float) {
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        let sinp = 2 * (w * y - z * x)
        let pitch = abs(sinp) >= 1 ? copysign(Float.pi / 2, sinp) : asin(sinp)
        let roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        return (yaw, pitch, roll)
    }

    private func eyeUniforms(eye: Int, viewRotation: simd_float4x4, aspect: Float, time: Float) -> EyeUniforms {
        let eyeX: Float = eyeCount == 2 ? (eye == 0 ? -ipd / 2 : ipd / 2) : 0
        let view = translation(SIMD3(-eyeX, 0, 0)) * viewRotation
        let projection = perspective(fovY: verticalFOV, aspect: aspect, near: 0.1, far: 900)
        let viewProjection = projection * view
        // Eye position in world space: camera rotation applied to the eye offset
        let eyeWorld = (viewRotation.transpose * SIMD4(eyeX, 0, 0, 0)).xyz
        return EyeUniforms(
            viewProjection: viewProjection,
            inverseViewProjection: viewProjection.inverse,
            sunDir: SIMD4(sunDirection, 0),
            cameraPos: SIMD4(eyeWorld, time),
            params: SIMD4(-eyeHeight, fogDensity, 0, 0)
        )
    }

    /// Projects geometry onto the ground plane along the sun direction (planar shadows).
    private func shadowMatrix() -> simd_float4x4 {
        let l = sunDirection
        let h = -eyeHeight + 0.02
        let kx = l.x / l.y
        let kz = l.z / l.y
        return simd_float4x4(rows: [
            SIMD4(1, -kx, 0, kx * h),
            SIMD4(0, 0, 0, h),
            SIMD4(0, -kz, 1, kz * h),
            SIMD4(0, 0, 0, 1),
        ])
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

        let time = Float(CACurrentMediaTime() - startTime)
        let viewRotation = headViewRotation()
        let fullWidth = Double(view.drawableSize.width)
        let fullHeight = Double(view.drawableSize.height)
        let eyeWidth = fullWidth / Double(eyeCount)
        let aspect = Float(eyeWidth / fullHeight)

        var identity = matrix_identity_float4x4
        var shadow = shadowMatrix()
        encoder.setCullMode(.none)

        for eye in 0..<eyeCount {
            encoder.setViewport(MTLViewport(originX: Double(eye) * eyeWidth, originY: 0,
                                            width: eyeWidth, height: fullHeight, znear: 0, zfar: 1))
            var uniforms = eyeUniforms(eye: eye, viewRotation: viewRotation, aspect: aspect, time: time)
            let uniformSize = MemoryLayout<EyeUniforms>.stride

            // Sky
            encoder.setDepthStencilState(noDepthState)
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setFragmentBytes(&uniforms, length: uniformSize, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            encoder.setDepthStencilState(depthState)
            encoder.setVertexBytes(&uniforms, length: uniformSize, index: 2)
            encoder.setFragmentBytes(&uniforms, length: uniformSize, index: 2)

            // Ground
            encoder.setRenderPipelineState(groundPipeline)
            encoder.setVertexBuffer(groundVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&identity, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: groundVertexCount)

            // Shadows: the stones projected onto the ground along the sun direction
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setVertexBuffer(stoneVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&shadow, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stoneVertexCount)

            // Stones
            encoder.setRenderPipelineState(stonePipeline)
            encoder.setVertexBytes(&identity, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stoneVertexCount)
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

private func rotationX(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(1, 0, 0, 0),
        SIMD4(0, c, -s, 0),
        SIMD4(0, s, c, 0),
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

private func rotationZ(_ a: Float) -> simd_float4x4 {
    let c = cos(a), s = sin(a)
    return simd_float4x4(rows: [
        SIMD4(c, -s, 0, 0),
        SIMD4(s, c, 0, 0),
        SIMD4(0, 0, 1, 0),
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

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
