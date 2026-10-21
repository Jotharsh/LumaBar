# Contributing

Bug reports and pull requests are welcome. The most useful thing right now is **testing with real bulbs**:
only WiZ has been verified on hardware, so reports for the other brands (what worked, what didn't, your bulb model) are very valuable.

## Setup

```sh
git clone https://github.com/Jotharsh/LumaBar.git
cd LumaBar
swift build        # debug build
swift test         # ~225 tests, all against simulated devices: no bulbs needed
./scripts/build.sh # builds dist/LumaBar.app
```

You need macOS 13+ and Xcode (or its command line tools) with Swift 5.9+.

## Adding or fixing a driver

Each brand implements `BulbDriver` (see `Sources/LumaBarCore/Drivers/BulbDriver.swift`) and lives in its own folder.
New drivers should come with tests against a simulated device (see `Tests/LumaBarCoreTests/FakeTuya.swift` and `FakeUDPDevice.swift` for examples), and a `DriverHelp` explaining setup and what to check when the bulb can't be reached.
Register the driver in `Sources/LumaBar/Drivers.swift`.

## Guidelines

- Keep secrets (keys, tokens) out of source, logs, `UserDefaults` and saved bulbs: use `SecretStore`.
- The UI and automations must only talk to `BulbDriver`, never to a specific brand.
- Run `swift test` before opening a pull request.

`scripts/fake_bulb.py` pretends to be a WiZ bulb, which is handy for trying the app without hardware.
