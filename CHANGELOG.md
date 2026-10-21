# Changelog

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
