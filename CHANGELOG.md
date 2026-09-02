# Changelog

## 3.0.0 — Cinema Edition (2026-09-02)

Fork of [DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) v2.0.0.

### Added
- Four explicit, mutually exclusive modes in the menu: extra display, mirror of the built-in display, stereo 3D chairs demo, cinema.
- Control of the glasses' display mode over USB HID (`device_mcu.c`, `XRealMCUService`): switch to side-by-side 3D and back, read/set brightness. Verified on Air 2 Pro (`0x03` = SBS, `0x0B` = factory 2D 120 Hz).
- Side-by-side stereo renderer (Metal, one pass per eye) with head tracking from the IMU; demo scene of twelve chairs around the viewer.
- Cinema: file picker, fullscreen playback on the glasses only, audio routed to the glasses' USB speakers, transport panel in the menu (play/pause, stop, seek with time, volume).
- Double tap on the glasses pauses/resumes the cinema (accelerometer-based `TapDetector`).
- Automatic best native display mode for the glasses (1920×1080@120) at launch, on hot-plug and after leaving 3D; menu item shows the current mode.
- Unplug handling: output windows hide the instant the glasses' display vanishes, sound stops, every mode shuts down, the app returns to the extra-display mode. Glasses that reconnect in 3D are put back to 2D.
- Development launch arguments `--stereo` and `--cinema <file>`.
- Russian UI.

### Fixed
- Output window was placed half off the glasses' screen: `NSWindow(contentRect:…, screen:)` takes a rect relative to that screen, not global coordinates (also affected the original spatial mode).
- macOS picked a downscaled 800×600 / 1024×576 mode for the glasses; the app now selects native 1:1 modes only.
- Crash in `hid_enumerate` when polling glasses presence from the main thread while the IMU thread used hidapi; presence is now an IOKit registry query.
- Glasses were left in 3D when the app quit while still waiting for the display; restore is now synchronous on exit and covers the pending state.
- Per-sample debug printing in the vendored IMU driver (three lines per sample at ~1 kHz) is now behind `XREAL_IMU_TRACE_SAMPLES`.

### Removed
- Static ultrawide virtual display and the head-tracked floating display from the original project, together with the private `CGVirtualDisplay` API, ScreenCaptureKit capture and the screen-recording permission.
- Resolution presets and spatial sensitivity/smoothing settings.
