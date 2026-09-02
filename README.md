# UltraXReal — Cinema Edition

macOS menu bar app for XReal Air glasses. A fork of [DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide)
that replaces the virtual ultrawide display with four explicit modes and adds USB control of the glasses.

## Modes

| ⌘ | Mode | What it does |
|---|------|--------------|
| 1 | **Extended Display** | The glasses are a plain extended display at native 1920×1080@120. Default. |
| 2 | **Mirror Main Display** | The glasses mirror the built-in display. |
| 3 | **Cinema…** | Pick a video: it plays fullscreen on the glasses only, sound goes to the glasses' speakers. Transport panel in the menu; **double-tap the glasses** to pause/resume. |
| 4 | **Demo: 3D** | The glasses switch to side-by-side 3D and you stand inside Stonehenge (procedural sky, grass, stones, shadows, no textures). Turn your head to look around, ⌘⇧R recenters. |

Always on: the glasses are set to their best native mode on launch and hot-plug; unplugging them
shuts everything down instantly; glasses left in 3D (crash, kill) are put back to 2D.

## How it works

- **Glasses display mode** over USB HID (`device_mcu.c`, `XRealMCUService`): 2D ↔ side-by-side 3D, brightness.
  Verified on Air 2 Pro: `0x03` = SBS 3840×1080@60, `0x0B` = factory 2D 1920×1080@120.
- **Head tracking**: vendored IMU driver ([xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos)) +
  [Fusion](https://github.com/xioTechnologies/Fusion) Madgwick filter; auto-reconnects.
- **Stereo**: one Metal pass per eye into each half of a fullscreen window on the glasses.
- **Cinema**: `AVPlayer` in a window on the glasses' screen, audio routed via `audioOutputDeviceUniqueID`.
- **Taps**: linear-acceleration peaks from the IMU.
- All hidapi traffic is serialised on one queue; presence is detected through the IOKit registry.

## Requirements

- macOS 13+ (tested on macOS 26, Apple Silicon), XReal Air 2 Pro (other Air models recognised, MCU codes unverified).
- When macOS asks *"What do you want to show on Air 2 Pro?"*, choose **Extended Display** and **Set as Default**.

## Build

```bash
git clone https://github.com/AlexeySpiridonov/XReal-Ultrawide-cinemaEd.git
open XReal-Ultrawide-cinemaEd/UltraXReal/UltraXReal.xcodeproj
```

Sign to run locally, build, run. Not notarized: `xattr -cr` the app or allow it in *Privacy & Security*.
Dev arguments: `--stereo`, `--cinema <file>`.

## Known limitations

- Head-axis signs (`yawSign`, `pitchSign`, `rollSign` in `StereoSceneRenderer.swift`) were tuned by feel on one pair.
- Switching the glasses to 3D and back takes 8–25 s (they re-enumerate as a new display). 3DoF only.
- Tap threshold (0.6 g) tuned on Air 2 Pro.

See [CHANGELOG.md](CHANGELOG.md) for what changed from upstream.

## Credits & license

[DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) (base),
[adidoes/xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos),
[xioTechnologies/Fusion](https://github.com/xioTechnologies/Fusion),
[TheJackiMonster/nrealAirLinuxDriver](https://gitlab.com/TheJackiMonster/nrealAirLinuxDriver) (MCU protocol),
[libusb/hidapi](https://github.com/libusb/hidapi). MIT, see [LICENSE](LICENSE).

---

**По-русски:** форк UltraXReal для очков XReal Air, четыре режима: дополнительный дисплей, зеркало, кинотеатр
(видео и звук только в очки, двойной стук ставит на паузу) и стерео-демо внутри Стоунхенджа.
Проверено на Air 2 Pro и macOS 26.
