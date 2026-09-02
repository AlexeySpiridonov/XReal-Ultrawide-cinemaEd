# UltraXReal — Cinema Edition

**macOS menu bar app for XReal Air glasses: extra display, mirror, stereo 3D demo and a private cinema.**

A fork of [DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) (UltraXReal v2.0.0).
The original project turned the glasses into a static ultrawide monitor and a head-tracked floating display.
This edition keeps its foundation (menu bar app, vendored IMU driver, glasses detection) and replaces the
feature set with four explicit modes, adds control of the glasses' own display mode over USB HID, real
side-by-side stereo rendering, a video player with sound routed into the glasses, and tap gestures.
The UI is in Russian.

---

## Modes

Exactly one mode is active at a time. Switch from the menu bar icon (⌘1 … ⌘4).

| # | Mode | What it does |
|---|------|--------------|
| 1 | **Дополнительный дисплей** | The glasses are a plain extended display at their native 1920×1080@120. Default state. |
| 2 | **Зеркало основного дисплея** | The glasses mirror the built-in display. |
| 3 | **3D-стулья** | Stereo demo: the glasses switch to side-by-side 3D (3840×1080), you stand in the middle of a ring of twelve different chairs, head rotation moves the view. ⌘⇧R recenters. |
| 4 | **Кинотеатр…** | Pick a video file. It plays fullscreen on the glasses only, with sound routed to the glasses' speakers. Transport panel in the menu (play/pause, stop, seek, volume). **Double-tap the glasses to pause/resume.** |

Always on:

- The glasses are switched to their best native mode (1920×1080@120 on Air 2 Pro) at launch, on hot-plug and when leaving stereo.
- Unplugging the glasses shuts everything down instantly: output windows hide before macOS can move them to the Mac's display, sound stops, the app returns to mode 1.
- Glasses that come back in 3D mode (unplugged mid-stereo) are put back to 2D automatically.

---

## How it works

- **Display mode of the glasses** — `Vendor/xreal-imu/device_mcu.c` talks to the glasses' MCU over USB HID
  (packet format and commands from [nrealAirLinuxDriver](https://gitlab.com/TheJackiMonster/nrealAirLinuxDriver)):
  read/write display mode (2D ↔ side-by-side 3D) and brightness. Verified on Air 2 Pro: code `0x03` = SBS 3840×1080@60,
  the factory 2D code is `0x0B` (1920×1080@120). The app remembers the 2D code it read and restores exactly that.
- **Head tracking** — the vendored driver from [xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos)
  reads the ICM-42688-P IMU and runs the [Fusion](https://github.com/xioTechnologies/Fusion) Madgwick filter.
  `StereoSceneRenderer` converts the quaternion to yaw/pitch/roll with per-axis sign switches.
- **Stereo** — one Metal pass per eye into the left/right half of a fullscreen window on the glasses; the glasses show each half to one eye. IPD 63 mm, ~23° vertical FOV.
- **Cinema** — `AVPlayer` + `AVPlayerLayer` in a borderless window on the glasses' screen; `audioOutputDeviceUniqueID` points at the glasses' USB audio device found via CoreAudio.
- **Tap detection** — linear acceleration (gravity removed) from the IMU; a sharp peak above 0.6 g is a tap, two within 0.5 s is a double tap.
- **Presence watchdog** — IOKit registry query for HID devices with the XReal vendor ID (deliberately not hidapi, which is not thread-safe).

---

## Requirements

- macOS 13.0+ (developed and tested on macOS 26 / Apple Silicon)
- XReal Air 2 Pro (tested). Air, Air 2 and Air 2 Ultra are recognised by the driver but the MCU display-mode codes were only verified on Air 2 Pro.
- Xcode 15+ with the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain` if missing)

When the glasses (re)connect, macOS 26 asks *"What do you want to show on Air 2 Pro?"* — choose **Extended Display** and tick **Set as Default**. The app needs the glasses as a separate screen.

## Build

```bash
git clone https://github.com/AlexeySpiridonov/XReal-Ultrawide-cinemaEd.git
cd XReal-Ultrawide-cinemaEd/UltraXReal
open UltraXReal.xcodeproj
```

Select *Sign to Run Locally*, build and run. The icon appears in the menu bar (no dock icon).

Development launch arguments: `--stereo` starts the chairs right away, `--cinema <file>` starts the cinema with that file.

---

## Project layout

```
UltraXReal/UltraXReal/
├── UltraXRealApp.swift            # entry point
├── AppDelegate.swift              # menu, the four modes, watchdog, hot-plug
├── DisplayMirrorHelper.swift      # find the glasses' display, best mode, mirroring
├── Settings.swift                 # launch at login
├── UltraXReal-Bridging-Header.h   # exposes the C drivers to Swift
├── Spatial/
│   ├── XRealIMUService.swift      # IMU stream (orientation, linear acceleration), USB presence
│   ├── XRealMCUService.swift      # glasses display mode / brightness over HID
│   ├── StereoSceneRenderer.swift  # side-by-side Metal renderer, chairs scene
│   ├── StereoShaders.metal
│   ├── CinemaPlayer.swift         # video on the glasses, audio to the glasses
│   ├── CinemaControlView.swift    # transport panel in the menu
│   └── TapDetector.swift
└── Vendor/
    ├── hidapi/
    ├── fusion/                    # Madgwick AHRS
    └── xreal-imu/                 # IMU protocol (from xrealair-sdk-macos) + device_mcu.c (new)
```

---

## Known limitations

- Head-axis signs were tuned by feel on one pair of glasses (`yawSign`, `pitchSign`, `rollSign` in `StereoSceneRenderer.swift`). Flip one if an axis feels inverted.
- Switching the glasses to 3D and back takes 8–26 s (they re-enumerate as a new display).
- 3DoF only: rotation, no positional tracking.
- Tap threshold (0.6 g) was tuned on Air 2 Pro; peaks are logged to help re-tuning.
- Private `CGVirtualDisplay` API from the original project is no longer used, so the app has no private-API dependency any more, but it is still not notarized: run `xattr -cr` on the app or allow it in *Privacy & Security*.

## What changed from upstream

See [CHANGELOG.md](CHANGELOG.md).

## Credits

- [DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) — the original UltraXReal this fork is based on (MIT).
- [adidoes/xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos) — IMU driver.
- [xioTechnologies/Fusion](https://github.com/xioTechnologies/Fusion) — sensor fusion.
- [TheJackiMonster/nrealAirLinuxDriver](https://gitlab.com/TheJackiMonster/nrealAirLinuxDriver) — MCU packet format and display-mode command.
- [libusb/hidapi](https://github.com/libusb/hidapi).

## License

MIT, same as the original project. See [LICENSE](LICENSE).

---

## Кратко по-русски

Форк UltraXReal от DannyDesert. Программа в строке меню для очков XReal Air с четырьмя режимами:
дополнительный дисплей, зеркало основного дисплея, стерео-демо со стульями вокруг, кинотеатр
(видео и звук только в очки, двойной стук по очкам ставит на паузу). Очки сами переводятся в максимальное
разрешение, при отключении очков всё гасится. Проверено на XReal Air 2 Pro и macOS 26.
