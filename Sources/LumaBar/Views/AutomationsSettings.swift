import SwiftUI
import LumaBarCore

struct AutomationsSettings: View {
    @EnvironmentObject private var settings: AutomationSettings
    @EnvironmentObject private var manager: AutomationManager

    var body: some View {
        Form {
            CalendarSection(automation: manager.calendar)
            SunsetSection(automation: manager.sunset)
            ScreenSection(automation: manager.screenSync)
            WebcamSection(automation: manager.webcam)
        }
        .formStyle(.grouped)
    }
}

private struct StatusLine: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct CalendarSection: View {
    @EnvironmentObject private var settings: AutomationSettings
    @ObservedObject var automation: CalendarAutomation

    var body: some View {
        Section("Calendar scenes") {
            Toggle("Change the light color during meetings", isOn: $settings.calendarEnabled)
            if settings.calendarEnabled {
                HStack {
                    Text("Meeting color")
                    GradientSlider(value: $settings.calendarHue, range: 0...1, colors: Color.rainbow)
                    Circle().fill(Color(hue: settings.calendarHue, saturation: 1, brightness: 1)).frame(width: 16, height: 16)
                }
                Toggle("Only events that have other attendees", isOn: $settings.calendarOnlyWithAttendees)
                StatusLine(text: automation.status)
            }
            StatusLine(text: "Restores the light to how it was when the meeting ends. All-day, declined and \"free\" events are ignored.")
        }
    }
}

private struct SunsetSection: View {
    @EnvironmentObject private var settings: AutomationSettings
    @ObservedObject var automation: SunsetAutomation

    var body: some View {
        Section("Sunset") {
            Toggle("Gradually dim and warm the light after sunset", isOn: $settings.sunsetEnabled)
            if settings.sunsetEnabled {
                Slider(value: $settings.sunsetRampMinutes, in: 15...180, step: 5) { Text("Over \(Int(settings.sunsetRampMinutes)) min") }
                Slider(value: $settings.sunsetTargetBrightness, in: 10...100, step: 5) { Text("Down to \(Int(settings.sunsetTargetBrightness))%") }
                Slider(value: $settings.sunsetTargetTemperature, in: 2200...4000, step: 100) { Text("Warm to \(Int(settings.sunsetTargetTemperature))K") }
                StatusLine(text: automation.status)
            }
            StatusLine(text: "Uses your location once to find sunset. Only runs while the light is on, and leaves it alone once the ramp is done.")
        }
    }
}

private struct ScreenSection: View {
    @EnvironmentObject private var settings: AutomationSettings
    @ObservedObject var automation: ScreenSyncAutomation

    var body: some View {
        Section("Screen color sync") {
            Toggle("Mirror my screen's average color", isOn: $settings.screenSyncEnabled)
            if settings.screenSyncEnabled { StatusLine(text: automation.status) }
            StatusLine(text: "Needs Screen Recording permission. Updates at most about 3 times a second to keep the bulb happy.")
        }
    }
}

private struct WebcamSection: View {
    @EnvironmentObject private var settings: AutomationSettings
    @ObservedObject var automation: WebcamAutomation

    var body: some View {
        Section("Video calls") {
            Toggle("Use the \"Video Call\" preset when a camera is on", isOn: $settings.webcamEnabled)
            if settings.webcamEnabled { StatusLine(text: automation.status) }
            StatusLine(text: "Edit that preset under Presets. The light goes back to how it was a few seconds after the camera turns off.")
        }
    }
}
