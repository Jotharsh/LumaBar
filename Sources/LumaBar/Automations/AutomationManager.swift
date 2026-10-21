import Combine
import Foundation
import LumaBarCore

/// Stops automations from fighting over the bulb.
///
/// Automations that change the light *temporarily* (meeting colour, video-call preset, screen sync)
/// take a claim with a priority. The highest priority wins, and only it may write to the bulbs.
/// The bulbs' original state is captured when the first claim is taken and restored when the last
/// one ends, so overlapping automations (a meeting that includes a video call) unwind correctly.
@MainActor
final class AutomationArbiter {
    enum Priority {
        static let sunset = 0
        static let screenSync = 1
        static let calendar = 2
        static let webcam = 3
    }

    private struct Claim {
        let priority: Int
        let apply: () -> Void
    }

    private let store: BulbStore
    private var claims: [String: Claim] = [:]
    private var original: [String: LightCommand] = [:]
    private var capturing = false

    init(store: BulbStore) {
        self.store = store
    }

    private var topPriority: Int { claims.values.map(\.priority).max() ?? -1 }

    /// Whether an automation with this priority may currently write to the bulbs.
    func allows(priority: Int) -> Bool { priority >= topPriority }

    func begin(_ owner: String, priority: Int, apply: @escaping () -> Void) async {
        if claims.isEmpty && !capturing {
            capturing = true
            original = await store.captureSnapshot()
            capturing = false
        }
        claims[owner] = Claim(priority: priority, apply: apply)
        if allows(priority: priority) { apply() }
    }

    func end(_ owner: String) {
        guard let ended = claims.removeValue(forKey: owner) else { return }
        if claims.isEmpty {
            store.restore(original)
            original = [:]
        } else if ended.priority > topPriority {
            // A lower-priority automation is still active; bring its look back.
            claims.values.max { $0.priority < $1.priority }?.apply()
        }
    }
}

/// Owns the four automations and starts/stops them as their settings change.
@MainActor
final class AutomationManager: ObservableObject {
    let settings: AutomationSettings
    let calendar: CalendarAutomation
    let sunset: SunsetAutomation
    let screenSync: ScreenSyncAutomation
    let webcam: WebcamAutomation
    private var cancellables = Set<AnyCancellable>()

    init(store: BulbStore, settings: AutomationSettings) {
        let arbiter = AutomationArbiter(store: store)
        self.settings = settings
        calendar = CalendarAutomation(store: store, settings: settings, arbiter: arbiter)
        sunset = SunsetAutomation(store: store, settings: settings, arbiter: arbiter)
        screenSync = ScreenSyncAutomation(store: store, arbiter: arbiter)
        webcam = WebcamAutomation(store: store, arbiter: arbiter)

        bind(settings.$calendarEnabled, start: { [calendar] in calendar.start() }, stop: { [calendar] in calendar.stop() })
        bind(settings.$sunsetEnabled, start: { [sunset] in sunset.start() }, stop: { [sunset] in sunset.stop() })
        bind(settings.$screenSyncEnabled, start: { [screenSync] in screenSync.start() }, stop: { [screenSync] in screenSync.stop() })
        bind(settings.$webcamEnabled, start: { [webcam] in webcam.start() }, stop: { [webcam] in webcam.stop() })
    }

    private func bind(_ flag: Published<Bool>.Publisher, start: @escaping @MainActor () -> Void, stop: @escaping @MainActor () -> Void) {
        flag.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { enabled in Task { @MainActor in enabled ? start() : stop() } }
            .store(in: &cancellables)
    }
}
