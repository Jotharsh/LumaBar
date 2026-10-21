import Foundation
import LumaBarCore

/// The one place that knows which concrete drivers exist. Everything else uses `BulbDriver`.
///
/// Setup wizards need their own driver's setup calls (pairing, saving a token), so the typed
/// instances are kept here too. Day-to-day control never goes through them.
struct DriverSet {
    let secrets: SecretStore
    let wiz: WizDriver
    let tuya: TuyaDriver
    let yeelight: YeelightDriver
    let lifx: LifxDriver
    let hue: HueDriver
    let homeAssistant: HomeAssistantDriver

    var registry: DriverRegistry {
        DriverRegistry(drivers: [wiz, tuya, yeelight, lifx, hue, homeAssistant])
    }

    init(secrets: SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        // LUMABAR_BULB_PORT points the app at a fake bulb on another port (see scripts/fake_bulb.py).
        let wizPort = ProcessInfo.processInfo.environment["LUMABAR_BULB_PORT"].flatMap { UInt16($0) } ?? WizLimits.port
        wiz = WizDriver(client: WizClient(bulbPort: wizPort))
        tuya = TuyaDriver(secrets: secrets)
        yeelight = YeelightDriver()
        lifx = LifxDriver()
        hue = HueDriver(secrets: secrets)
        homeAssistant = HomeAssistantDriver(secrets: secrets)
    }
}
