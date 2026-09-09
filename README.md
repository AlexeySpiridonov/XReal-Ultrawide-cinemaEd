# GlassesHUD

iPhone app that puts a GPS head-up display on XReal Air glasses (or any USB-C display).

- Plug the glasses into an iPhone with USB-C (iPhone 15 or later). iOS treats them as an external display;
  the app opens its own scene there instead of mirroring the phone.
- The glasses show, on a black (= transparent) background: speed, heading, altitude, clock and GPS accuracy,
  and the distance plus a direction arrow to a target you tap on the map.
- The phone shows status, a live preview of the HUD, what to display, units, heading source and the map.

No head tracking: iOS gives third-party apps no access to the glasses' USB HID interfaces, so the HUD is
head-locked like a normal monitor. Heading comes from the phone: GPS course while moving, compass otherwise.

Build: open `GlassesHUD.xcodeproj`, set your team under Signing, run on a device (iOS 17+).
