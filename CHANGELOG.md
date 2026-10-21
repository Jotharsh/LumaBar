# Changelog

## 1.0.1

- **Clearer help when macOS blocks LumaBar from the local network.** The "Can't reach" card now says so directly, with a button to the right System Settings pane, instead of showing generic bulb advice. Applies to every brand.
- The card shows the technical reason a connection failed ("More things to check" > "Technical detail"), which makes problems much easier to report and diagnose.
- LumaBar no longer reports a vague timeout when macOS gave a specific reason.
- Fixed the "Video Call" preset button being cut off ("Video C...").
- Release builds can go to a separate folder (`OUT_DIR=...`), so rebuilding doesn't replace the copy you're running.
- More tests (232 in total).
- Added a screenshot to the README.

## 1.0.0

First public release.

- Menu bar app for macOS 13+ (no Dock icon) to control smart bulbs on your local network.
- Power, brightness, warm/cool white, colour (hue + saturation + swatches), presets.
- All 32 WiZ scenes by name, with a speed slider for animated scenes.
- Brands: WiZ, Tuya / Smart Life (protocol 3.3 and 3.4), Yeelight, LIFX, Philips Hue, and Home Assistant.
- Automatic discovery where the brand supports it; manual IP fallback; bulbs are remembered between launches.
- Tuya local keys, Hue pairing keys and the Home Assistant token are stored in the macOS Keychain.
- Controls shown depend on what each bulb supports.
- Clear, brand-specific help when a bulb can't be reached.
- Global hotkeys: toggle light, brightness up/down.
- Optional automations (off by default): calendar meeting colour, sunset dimming, screen colour sync, camera-on "Video Call" preset.

Known limitations: only WiZ has been verified against real hardware. The app is not
notarized (see the README for first-launch steps).
