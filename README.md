# XReal Workbench

Two open-source apps for XReal Air glasses: a macOS menu bar app that drives the glasses themselves,
and an iPhone app that puts a GPS head-up display on them.

**[→ Project page / промо-страница](https://alexeyspiridonov.github.io/XReal-Ultrawide-cinemaEd/)** — what it looks like through the lenses, how it works, and the numbers that were actually measured.

| Folder | App | Platform |
|--------|-----|----------|
| [`UltraXReal/`](UltraXReal) | **UltraXReal — Cinema Edition**: extended display, mirror, cinema, stereo 3D demo | macOS 13+ |
| [`GlassesHUD/`](GlassesHUD) | **GlassesHUD**: speed, heading, altitude, roads and route on the glasses | iOS 17+ |

Both are MIT. Tested on XReal Air 2 Pro.

---

## UltraXReal — Cinema Edition (macOS)

A fork of [DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) that replaces
the virtual ultrawide display with four explicit modes and adds USB control of the glasses.

| ⌘ | Mode | What it does |
|---|------|--------------|
| 1 | **Extended Display** | The glasses are a plain extended display at native 1920×1080@120. Default. |
| 2 | **Mirror Main Display** | The glasses mirror the built-in display. |
| 3 | **Cinema…** | Pick a video: it plays fullscreen on the glasses only, sound goes to the glasses' speakers. Transport panel in the menu; **double-tap the glasses** to pause/resume. |
| 4 | **Demo: 3D** | The glasses switch to side-by-side 3D and you stand inside Stonehenge (procedural sky, grass, stones, shadows, no textures). Turn your head to look around, ⌘⇧R recenters. |

Always on: the glasses are set to their best native mode on launch and hot-plug; unplugging them
shuts everything down instantly; glasses left in 3D (crash, kill) are put back to 2D.

**How it works**

- **Glasses display mode** over USB HID (`device_mcu.c`, `XRealMCUService`): 2D ↔ side-by-side 3D, brightness.
  Verified on Air 2 Pro: `0x03` = SBS 3840×1080@60, `0x0B` = factory 2D 1920×1080@120.
- **Head tracking**: vendored IMU driver ([xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos)) +
  [Fusion](https://github.com/xioTechnologies/Fusion) Madgwick filter; auto-reconnects.
- **Stereo**: one Metal pass per eye into each half of a fullscreen window on the glasses.
- **Cinema**: `AVPlayer` in a window on the glasses' screen, audio routed via `audioOutputDeviceUniqueID`.
- **Taps**: linear-acceleration peaks from the IMU.
- All hidapi traffic is serialised on one queue; presence is detected through the IOKit registry.

**Build**

```bash
git clone https://github.com/AlexeySpiridonov/XReal-Ultrawide-cinemaEd.git
open XReal-Ultrawide-cinemaEd/UltraXReal/UltraXReal.xcodeproj
```

Sign to run locally, build, run. Not notarized: `xattr -cr` the app or allow it in *Privacy & Security*.
Dev arguments: `--stereo`, `--cinema <file>`.

**Limitations**

- Head-axis signs (`yawSign`, `pitchSign`, `rollSign` in `StereoSceneRenderer.swift`) were tuned by feel on one pair.
- Switching the glasses to 3D and back takes 8–25 s (they re-enumerate as a new display). 3DoF only.
- Tap threshold (0.6 g) tuned on Air 2 Pro.
- When macOS asks *"What do you want to show on Air 2 Pro?"*, choose **Extended Display** and **Set as Default**.

See [CHANGELOG.md](CHANGELOG.md) for what changed from upstream.

---

## GlassesHUD (iOS)

Plug the glasses into an iPhone with USB-C (iPhone 15 or later). iOS treats them as an external
display and the app opens its own scene there instead of mirroring the phone.

**In the glasses**, on black (= transparent through the lenses):

- Left column: speed, heading with cardinal point, altitude, distance and time to the target, coordinates, clock and GPS accuracy.
- Right panel: the roads around you, heading-up, drawn as lines only — no basemap. You sit near the
  bottom with 100 m of road ahead (100 / 150 / 300 / 500 m selectable). The street you are on is drawn
  brighter and named above the panel. With a target set, the driving route runs across it as an orange dashed line.

**On the phone**: connection and GPS status, a live preview of the HUD, toggles for every element,
units, heading source, panel size, and a map where a tap sets the target.

**How it works**

- **Position and heading**: CoreLocation at navigation accuracy. GPS only reports once a second, so the
  heading is carried between fixes by the phone's gyroscope at 50 Hz (rotation about the gravity axis,
  so mounting orientation does not matter) and corrected by the GPS course; the position is dead-reckoned
  along that heading at the last known speed. The road canvas redraws every frame, so the map turns smoothly.
- **Roads**: OpenStreetMap geometry via the Overpass API, ~2 km around you, refetched after 400 m. Needs a network.
- **Route**: MapKit directions, recomputed when the target changes, when you stray 60 m off it, or every two minutes.
- **Street name**: reverse geocoding, throttled to 100 m / 10 s.

**Build**

```bash
open XReal-Ultrawide-cinemaEd/GlassesHUD/GlassesHUD.xcodeproj
```

Set your team under Signing & Capabilities, run on a device.

**Limitations**

- **No head tracking.** iOS gives third-party apps no access to the glasses' USB HID interfaces, so the
  HUD is head-locked like a normal monitor.
- **Do not lock the phone.** iOS freezes external-display scenes while the phone is locked. While the
  glasses are connected the app keeps the phone awake and dims its screen to zero instead; it must stay
  in the foreground.
- Roads and routing need a data connection; only the last fetched area is kept.

---

## Credits & license

[DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) (base of the macOS app),
[adidoes/xrealair-sdk-macos](https://github.com/adidoes/xrealair-sdk-macos) (IMU driver),
[xioTechnologies/Fusion](https://github.com/xioTechnologies/Fusion) (sensor fusion),
[TheJackiMonster/nrealAirLinuxDriver](https://gitlab.com/TheJackiMonster/nrealAirLinuxDriver) (MCU protocol),
[libusb/hidapi](https://github.com/libusb/hidapi). Maps from OpenStreetMap, routing from MapKit.
MIT, see [LICENSE](LICENSE).

XREAL and Air 2 Pro are trademarks of their owners; these projects are not affiliated with XREAL.

---

**По-русски:** два открытых приложения для очков XReal Air. `UltraXReal/` — программа в строке меню macOS
с четырьмя режимами: дополнительный дисплей, зеркало, кинотеатр (видео и звук только в очки, двойной стук
ставит на паузу) и стерео-демо внутри Стоунхенджа. `GlassesHUD/` — приложение для iPhone, которое выводит
в очки скорость, курс, высоту, дороги вокруг и маршрут пунктиром. Проверено на Air 2 Pro и macOS 26.
