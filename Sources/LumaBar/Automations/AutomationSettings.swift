import Foundation

/// User-configurable automation options, persisted in UserDefaults.
@MainActor
final class AutomationSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: "auto.calendar.enabled") } }
    /// Hue 0...1 of the "in a meeting" colour.
    @Published var calendarHue: Double { didSet { defaults.set(calendarHue, forKey: "auto.calendar.hue") } }
    @Published var calendarOnlyWithAttendees: Bool { didSet { defaults.set(calendarOnlyWithAttendees, forKey: "auto.calendar.attendees") } }

    @Published var sunsetEnabled: Bool { didSet { defaults.set(sunsetEnabled, forKey: "auto.sunset.enabled") } }
    @Published var sunsetRampMinutes: Double { didSet { defaults.set(sunsetRampMinutes, forKey: "auto.sunset.minutes") } }
    @Published var sunsetTargetBrightness: Double { didSet { defaults.set(sunsetTargetBrightness, forKey: "auto.sunset.brightness") } }
    @Published var sunsetTargetTemperature: Double { didSet { defaults.set(sunsetTargetTemperature, forKey: "auto.sunset.temp") } }

    @Published var screenSyncEnabled: Bool { didSet { defaults.set(screenSyncEnabled, forKey: "auto.screen.enabled") } }
    @Published var webcamEnabled: Bool { didSet { defaults.set(webcamEnabled, forKey: "auto.webcam.enabled") } }

    init() {
        func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? fallback }

        calendarEnabled = bool("auto.calendar.enabled", false)
        calendarHue = double("auto.calendar.hue", 0)             // red
        calendarOnlyWithAttendees = bool("auto.calendar.attendees", true)
        sunsetEnabled = bool("auto.sunset.enabled", false)
        sunsetRampMinutes = double("auto.sunset.minutes", 60)
        sunsetTargetBrightness = double("auto.sunset.brightness", 35)
        sunsetTargetTemperature = double("auto.sunset.temp", 2200)
        screenSyncEnabled = bool("auto.screen.enabled", false)
        webcamEnabled = bool("auto.webcam.enabled", false)
    }
}
