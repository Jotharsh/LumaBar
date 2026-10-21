import EventKit
import Foundation
import LumaBarCore

/// Turns the light a chosen colour while a calendar event is in progress, then restores it.
@MainActor
final class CalendarAutomation: ObservableObject {
    @Published private(set) var status = "Off"

    private let store: BulbStore
    private let settings: AutomationSettings
    private let arbiter: AutomationArbiter
    private let events = EKEventStore()
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var running = false
    private var inMeeting = false

    init(store: BulbStore, settings: AutomationSettings, arbiter: AutomationArbiter) {
        self.store = store
        self.settings = settings
        self.arbiter = arbiter
    }

    func start() {
        guard !running else { return }
        running = true
        status = "Requesting calendar access…"
        Task { [weak self] in
            guard let self else { return }
            let granted = await requestAccess()
            guard running else { return }
            guard granted else {
                status = "Calendar access denied. Allow LumaBar in System Settings ▸ Privacy & Security ▸ Calendars."
                return
            }
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            }
            changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            }
            evaluate()
        }
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        if inMeeting { arbiter.end("calendar"); inMeeting = false }
        status = "Off"
    }

    private func requestAccess() async -> Bool {
        if #available(macOS 14, *) {
            return (try? await events.requestFullAccessToEvents()) ?? false
        }
        return await withCheckedContinuation { continuation in
            events.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    private func currentMeeting() -> EKEvent? {
        let now = Date()
        let predicate = events.predicateForEvents(withStart: now, end: now.addingTimeInterval(1), calendars: nil)
        return events.events(matching: predicate).first { event in
            guard !event.isAllDay, event.status != .canceled, event.availability != .free,
                  event.startDate <= now, event.endDate > now else { return false }
            if settings.calendarOnlyWithAttendees && !event.hasAttendees { return false }
            if event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined { return false }
            return true
        }
    }

    private func evaluate() {
        guard running else { return }
        if let meeting = currentMeeting() {
            status = "In a meeting: \(meeting.title ?? "Untitled")"
            guard !inMeeting else { return }
            inMeeting = true
            let params = LightCommand(state: true, rgb: ColorMath.rgb(hue: settings.calendarHue))
            Task {
                await arbiter.begin("calendar", priority: AutomationArbiter.Priority.calendar) { [store] in store.sendToAll(params) }
                // The meeting may have ended while the original light state was being captured.
                if !inMeeting { arbiter.end("calendar") }
            }
        } else {
            status = "On. Waiting for your next meeting."
            guard inMeeting else { return }
            inMeeting = false
            arbiter.end("calendar")
        }
    }
}
