import SwiftUI
import LumaBarCore

/// Settings ▸ Drivers: switch each brand on or off, read how to set it up, and run its setup wizard.
struct DriversSettings: View {
    @EnvironmentObject private var store: BulbStore

    var body: some View {
        Form {
            Section {
                Text("Turn on the brands you own. Each one only talks to its own bulbs, and switching one off hides its bulbs without deleting them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.registry.drivers, id: \.id) { driver in
                DriverSection(driver: driver)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DriverSection: View {
    @EnvironmentObject private var store: BulbStore
    let driver: any BulbDriver

    private var enabled: Binding<Bool> {
        Binding(get: { store.enabledDrivers.contains(driver.id) }, set: { store.setDriver(driver.id, enabled: $0) })
    }

    private var bulbCount: Int { store.savedBulbs.filter { $0.driverID == driver.id }.count }

    var body: some View {
        Section {
            Toggle(isOn: enabled) {
                HStack {
                    Text(driver.displayName).font(.body.weight(.medium))
                    if bulbCount > 0 {
                        Text("\(bulbCount) bulb\(bulbCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if enabled.wrappedValue {
                DisclosureGroup("How to set up \(driver.displayName)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(driver.help.setup.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)").fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
                DriverSetupView.make(for: driver)
            }
        }
    }
}

/// Brand-specific setup wizards. Day-to-day control never uses these; they exist because pairing and
/// credentials differ per brand.
enum DriverSetupView {
    @ViewBuilder
    static func make(for driver: any BulbDriver) -> some View {
        switch driver.id {
        case TuyaDriver.driverID:
            if let tuya = driver as? TuyaDriver { TuyaSetupView(driver: tuya) }
        case YeelightDriver.driverID, LifxDriver.driverID:
            DiscoverySetupView(driver: driver)
        case HueDriver.driverID:
            if let hue = driver as? HueDriver { HueSetupView(driver: hue) }
        case HomeAssistantDriver.driverID:
            if let ha = driver as? HomeAssistantDriver { HomeAssistantSetupView(driver: ha) }
        default:
            EmptyView()
        }
    }
}
