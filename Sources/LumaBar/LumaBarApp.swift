import SwiftUI
import LumaBarCore

/// Everything long-lived. It's created at launch (not when the menu is first opened) so hotkeys work immediately.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let drivers = DriverSet()
    let store: BulbStore
    let automationSettings = AutomationSettings()
    let automations: AutomationManager

    private init() {
        store = BulbStore(registry: drivers.registry)
        automations = AutomationManager(store: store, settings: automationSettings)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.store.start() }
    }
}

@main
struct LumaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = AppModel.shared.store

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            Image(systemName: store.isOn ? "lightbulb.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(AppModel.shared.automationSettings)
                .environmentObject(AppModel.shared.automations)
        }
    }
}
