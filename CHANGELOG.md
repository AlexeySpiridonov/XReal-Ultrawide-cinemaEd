# Changelog

## 3.0.0 — Cinema Edition (2026-09-02)

Fork of [DannyDesert/XReal-Ultrawide](https://github.com/DannyDesert/XReal-Ultrawide) v2.0.0.

### Added
- Four explicit, mutually exclusive modes in the menu: extended display, mirror of the built-in display, cinema, stereo 3D demo.
- Control of the glasses' display mode over USB HID (`device_mcu.c`, `XRealMCUService`): switch to side-by-side 3D and back, read/set brightness. Verified on Air 2 Pro (`0x03` = SBS, `0x0B` = factory 2D 120 Hz).
- Side-by-side stereo renderer (Metal, one pass per eye) with head tracking from the IMU; demo scene: the viewer stands inside Stonehenge (procedural sky with clouds and distant hills, grass, rough stones with lichen, planar sun shadows, no textures).
- Cinema: file picker, fullscreen playback on the glasses only, audio routed to the glasses' USB speakers, transport panel in the menu (play/pause, stop, seek with time, volume).
- Double tap on the glasses pauses/resumes the cinema (accelerometer-based `TapDetector`).
- Automatic best native display mode for the glasses (1920×1080@120) at launch, on hot-plug and after leaving 3D; menu item shows the current mode.
- Unplug handling: output windows hide the instant the glasses' display vanishes, sound stops, every mode shuts down, the app returns to the extra-display mode. Glasses that reconnect in 3D are put back to 2D.
- Development launch arguments `--stereo` and `--cinema <file>`.

### Fixed
- All hidapi work (MCU commands, IMU open/close) is serialised on one queue (`GlassesHID`); MCU commands no longer race the IMU read thread.
- `XRealIMUService.stop()` waits for the read loop to exit before closing the device (was a use-after-free); the loop now reconnects by itself after a transient HID error (sleep/wake, loose cable).
- The fact that the app switched the glasses to 3D is recorded before any cancellation check, so quitting or switching modes mid-switch always restores 2D; quitting restores synchronously without the read-back round trip.
- Glasses found in side-by-side at launch (crash or kill mid-demo) are put back to 2D.
- Re-entering the 3D demo right after leaving it no longer waits a minute and falls back to mono: the side-by-side decision comes from the MCU, serialised after the pending restore.
- Only codes read while the panel is 2D are remembered as the glasses' 2D mode.
- Mirror mode is re-applied when the glasses' display re-enumerates with a new ID.
- Output windows (cinema, stereo) share one `GlassesOutputWindow`; side-by-side detection has one definition.
- Output window was placed half off the glasses' screen: `NSWindow(contentRect:…, screen:)` takes a rect relative to that screen, not global coordinates (also affected the original spatial mode).
- macOS picked a downscaled 800×600 / 1024×576 mode for the glasses; the app now selects native 1:1 modes only.
- Crash in `hid_enumerate` when polling glasses presence from the main thread while the IMU thread used hidapi; presence is now an IOKit registry query.
- Glasses were left in 3D when the app quit while still waiting for the display; restore is now synchronous on exit and covers the pending state.
- Per-sample debug printing in the vendored IMU driver (three lines per sample at ~1 kHz) is now behind `XREAL_IMU_TRACE_SAMPLES`.

### Removed
- Static ultrawide virtual display and the head-tracked floating display from the original project, together with the private `CGVirtualDisplay` API, ScreenCaptureKit capture and the screen-recording permission.
- Resolution presets and spatial sensitivity/smoothing settings.
