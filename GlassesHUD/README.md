# GlassesHUD

iPhone app that puts a GPS head-up display on XReal Air glasses (or any USB-C display).

Plug the glasses into an iPhone with USB-C (iPhone 15 or later). iOS treats them as an external
display and the app opens its own scene there instead of mirroring the phone.

## What you see

**In the glasses**, on black (= transparent through the lenses):

- Left column: speed, heading with cardinal point, altitude, distance and time to the target, coordinates, clock and GPS accuracy.
- Right panel: the roads around you, heading-up, drawn as lines only — no basemap. You sit near the
  bottom with 100 m of road ahead (100 / 150 / 300 / 500 m selectable). The street you are on is drawn
  brighter and named above the panel. With a target set, the driving route runs across it as an orange dashed line.

**On the phone**: connection and GPS status, a live preview of the HUD, toggles for every element,
units, heading source, panel size, and a map where a tap sets the target.

## How it works

- **Position and heading**: CoreLocation at navigation accuracy. GPS only reports once a second, so the
  heading is carried between fixes by the phone's gyroscope at 50 Hz (rotation about the gravity axis,
  so mounting orientation does not matter) and corrected by the GPS course; the position is dead-reckoned
  along that heading at the last known speed. The road canvas redraws every frame, so the map turns smoothly.
- **Roads**: OpenStreetMap geometry via the Overpass API, ~2 km around you, refetched after 400 m. Needs a network.
- **Route**: MapKit directions, recomputed when the target changes, when you stray 60 m off it, or every two minutes.
- **Street name**: reverse geocoding, throttled to 100 m / 10 s.

## Limitations

- **No head tracking.** iOS gives third-party apps no access to the glasses' USB HID interfaces, so the
  HUD is head-locked like a normal monitor.
- **Do not lock the phone.** iOS freezes external-display scenes while the phone is locked. While the
  glasses are connected the app keeps the phone awake and dims its screen to zero instead; it must stay
  in the foreground.
- Roads and routing need a data connection; only the last fetched area is kept.

## Build

Open `GlassesHUD.xcodeproj`, set your team under Signing & Capabilities, run on a device (iOS 17+).
