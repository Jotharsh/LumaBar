import Foundation

/// User-facing guidance for when a bulb can't be reached. Shared so every screen says the same thing.
public enum WizHelp {
    public static let localControl = "Make sure \"Allow local communication\" is enabled in the WiZ app and your Mac is on the same Wi-Fi as the bulb."

    public static let moreChecks = [
        "The bulb is powered on and shows as online in the WiZ app.",
        "Your Mac isn't on a guest network or VPN, which can block local traffic.",
        "System Settings ▸ Privacy & Security ▸ Local Network has LumaBar switched on.",
    ]
}
