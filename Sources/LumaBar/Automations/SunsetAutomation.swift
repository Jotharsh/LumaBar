import CoreLocation
import Foundation
import LumaBarCore

/// From sunset, gradually dims and warms the light over a configurable period, then leaves it alone.
@MainActor
final class SunsetAutomation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = "Off"

    private let store: BulbStore
    private let settings: AutomationSettings
    private let arbiter: AutomationArbiter
    private let manager = CLLocationManager()
    private var timer: Timer?
    private var running = false

    // The coordinates are cached so the schedule keeps working without asking again.
    private var coordinate: CLLocationCoordinate2D? = {
        let d = UserDefaults.standard
        guard d.object(forKey: "auto.sunset.lat") != nil else { return nil }
        return CLLocationCoordinate2D(latitude: d.double(forKey: "auto.sunset.lat"), longitude: d.double(forKey: "auto.sunset.lon"))
    }()

    // Today's ramp: where it started from, and whether it has finished.
    private var rampDay: Date?
    private var rampStart: (brightness: Double, temperature: Double)?
    private var finishedDay: Date?

    init(store: BulbStore, settings: AutomationSettings, arbiter: AutomationArbiter) {
        self.store = store
        self.settings = settings
        self.arbiter = arbiter
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        guard !running else { return }
        running = true
        requestLocationIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        status = "Off"
    }

    private func requestLocationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            break
        default:
            manager.requestLocation()
        }
    }

    // MARK: Schedule

    private func tick() {
        guard running else { return }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted, coordinate == nil {
            status = "Location access denied. Allow LumaBar in System Settings ▸ Privacy & Security ▸ Location Services."
            return
        }
        guard let coordinate else { status = "Waiting for your location…"; return }

        let now = Date()
        let calendar = Calendar.current
        guard let sunset = SunCalc.sunset(on: now, latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            status = "No sunset today at this latitude."
            return
        }
        let duration = settings.sunsetRampMinutes * 60
        let progress = SunsetRamp.progress(now: now, sunset: sunset, duration: duration)
        let formatter = DateFormatter(); formatter.timeStyle = .short
        let today = calendar.startOfDay(for: now)

        if now < sunset {
            status = "Sunset today at \(formatter.string(from: sunset)). Dimming starts then."
            rampStart = nil
            return
        }
        if finishedDay == today {
            status = "Done for today (sunset was \(formatter.string(from: sunset)))."
            return
        }
        // Started (or relaunched) after the ramp window already ended: don't suddenly dim a light
        // the user has set how they want it.
        if progress >= 1 && rampStart == nil {
            finishedDay = today
            status = "Done for today (sunset was \(formatter.string(from: sunset)))."
            return
        }
        guard arbiter.allows(priority: AutomationArbiter.Priority.sunset) else { return }
        guard store.isOn else { status = "Waiting: the light is off."; return }

        if rampDay != today || rampStart == nil {
            rampDay = today
            rampStart = (store.brightness, store.temperature)
        }
        guard let start = rampStart else { return }

        let brightness = SunsetRamp.interpolate(from: start.brightness, to: min(settings.sunsetTargetBrightness, start.brightness), progress: progress)
        let temperature = SunsetRamp.interpolate(from: start.temperature, to: min(settings.sunsetTargetTemperature, start.temperature), progress: progress)
        store.sendToAll(LightCommand(state: true, dimming: Int(brightness.rounded()), temp: Int(temperature.rounded())))

        if progress >= 1 {
            finishedDay = today
            status = "Done for today (sunset was \(formatter.string(from: sunset)))."
        } else {
            status = "Dimming: \(Int(progress * 100))% of the way (sunset \(formatter.string(from: sunset)))."
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if running { requestLocationIfNeeded(); tick() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            coordinate = location.coordinate
            UserDefaults.standard.set(location.coordinate.latitude, forKey: "auto.sunset.lat")
            UserDefaults.standard.set(location.coordinate.longitude, forKey: "auto.sunset.lon")
            tick()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if coordinate == nil { status = "Couldn't get your location: \(error.localizedDescription)" }
        }
    }
}
