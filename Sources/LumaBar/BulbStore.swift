import SwiftUI
import Network
import KeyboardShortcuts
import LumaBarCore

/// Single source of truth for the bulbs and what the UI shows. All commands go through here.
@MainActor
final class BulbStore: ObservableObject {
    // MARK: Published state

    /// Every saved bulb, including those of drivers that are currently switched off.
    @Published private(set) var savedBulbs: [Bulb] { didSet { save(savedBulbs, key: Keys.bulbs) } }
    /// Drivers the user has switched on in Settings. WiZ is on by default; the rest are opt-in.
    @Published private(set) var enabledDrivers: Set<String> { didSet { defaults.set(Array(enabledDrivers), forKey: Keys.enabledDrivers) } }
    /// ID of the bulb the controls act on; nil means every bulb.
    @Published var selection: String? {
        didSet {
            defaults.set(selection, forKey: Keys.selection)
            Task { await refresh() }
        }
    }
    @Published private(set) var isOn = false
    @Published var brightness: Double = 100
    @Published var temperature: Double = 2700
    @Published var hue: Double = 0.08
    @Published var saturation: Double = 1
    /// The scene the bulb is running, or nil when it's in plain white or colour mode.
    @Published private(set) var activeScene: LightScene?
    @Published var sceneSpeed: Double = Double(LightScene.defaultSpeed)
    @Published private(set) var isColorMode = false
    @Published var presets: [Preset] { didSet { save(presets, key: Keys.presets) } }
    @Published private(set) var offline: Set<String> = []
    @Published private(set) var isDiscovering = false
    /// A bulb replied but rejected a command, or something else went wrong that isn't about reachability.
    @Published private(set) var lastError: String?
    /// The last network search came back empty and there are no saved bulbs.
    @Published private(set) var discoveryFoundNothing = false

    // MARK: Internals

    let registry: DriverRegistry
    private let defaults: UserDefaults
    private let brightnessThrottle = Throttler()
    private let temperatureThrottle = Throttler()
    private let colorThrottle = Throttler()
    private let speedThrottle = Throttler()

    /// Commands are serialised per bulb: while one is in flight, newer ones are merged into a single
    /// pending command. That keeps UDP datagrams in order and means a stalled bulb can't build a backlog.
    private struct Channel {
        var inFlight = false
        var pending: LightCommand?
    }
    private var channels: [String: Channel] = [:]
    private var lastDiscovery = Date.distantPast

    private enum Keys {
        static let bulbs = "lumabar.bulbs"
        static let presets = "lumabar.presets"
        static let selection = "lumabar.selection"
        static let enabledDrivers = "lumabar.enabledDrivers"
    }

    init(registry: DriverRegistry, defaults: UserDefaults = .standard) {
        self.registry = registry
        self.defaults = defaults
        savedBulbs = Self.load([Bulb].self, key: Keys.bulbs, from: defaults) ?? []
        presets = Self.load([Preset].self, key: Keys.presets, from: defaults) ?? Preset.defaults
        selection = defaults.string(forKey: Keys.selection)
        enabledDrivers = (defaults.array(forKey: Keys.enabledDrivers) as? [String]).map(Set.init) ?? [WizDriver.driverID]
    }

    /// Call once at launch.
    func start() async {
        registerHotkeys()
        if bulbs.isEmpty { await discover() } else { await refresh() }
    }

    /// The bulbs the app is using: saved bulbs whose driver is switched on.
    var bulbs: [Bulb] { savedBulbs.filter { enabledDrivers.contains($0.driverID) } }

    private var targets: [Bulb] {
        if let selection, let bulb = bulbs.first(where: { $0.id == selection }) { return [bulb] }
        return bulbs
    }

    /// What the selected bulb(s) can do. The UI shows only these controls.
    var capabilities: DeviceCapabilities {
        targets.reduce(into: DeviceCapabilities()) { $0.formUnion($1.capabilities) }
    }

    /// Scenes offered by the selected bulbs' drivers.
    var availableScenes: [LightScene] {
        var seen = Set<Int>()
        return targets.filter { $0.capabilities.contains(.scenes) }
            .compactMap { registry.driver(for: $0) }
            .flatMap(\.scenes)
            .filter { seen.insert($0.id).inserted }
    }

    func driver(for bulb: Bulb) -> (any BulbDriver)? { registry.driver(for: bulb) }

    /// True when the bulb(s) the controls act on aren't answering, so the UI should explain how to fix it.
    var showConnectionHelp: Bool {
        if bulbs.isEmpty { return discoveryFoundNothing }
        return !targets.isEmpty && targets.allSatisfy { offline.contains($0.id) }
    }

    var connectionHeadline: String {
        if bulbs.isEmpty {
            let names = registry.drivers.filter { enabledDrivers.contains($0.id) }.map(\.displayName)
            return names.count == 1 ? "No \(names[0]) bulbs found" : "No bulbs found"
        }
        if targets.count == 1 { return "Can't reach \(targets[0].name)" }
        return "Can't reach your bulbs"
    }

    /// Driver-specific advice for whatever is wrong: the brands of the unreachable bulbs, or every
    /// enabled brand when nothing has been found yet.
    var connectionHelp: [DriverHelp] {
        let ids: [String]
        if bulbs.isEmpty {
            ids = registry.drivers.filter { enabledDrivers.contains($0.id) }.map(\.id)
        } else {
            var seen = Set<String>()
            ids = targets.filter { offline.contains($0.id) }.map(\.driverID).filter { seen.insert($0).inserted }
        }
        return ids.compactMap { registry.driver(id: $0)?.help }
    }

    // MARK: Controls (UI)

    func toggle() { setPower(!isOn) }

    func setPower(_ on: Bool) {
        isOn = on
        send(.power(on))
    }

    func setBrightness(_ value: Double) {
        brightness = value
        isOn = true
        brightnessThrottle.submit { [weak self] in self?.sendBrightness() }
    }

    func commitBrightness() {
        brightnessThrottle.flush { [weak self] in self?.sendBrightness() }
    }

    private func sendBrightness() {
        send(LightCommand(state: true, dimming: Int(brightness.rounded())))
    }

    func setTemperature(_ kelvin: Double) {
        temperature = kelvin
        isOn = true
        isColorMode = false
        temperatureThrottle.submit { [weak self] in self?.sendTemperature() }
    }

    func commitTemperature() {
        temperatureThrottle.flush { [weak self] in self?.sendTemperature() }
    }

    private func sendTemperature() {
        send(LightCommand(state: true, temp: Int(temperature.rounded())))
    }

    func setHue(_ value: Double) {
        hue = value
        isOn = true
        isColorMode = true
        colorThrottle.submit { [weak self] in self?.sendHue() }
    }

    func commitHue() {
        colorThrottle.flush { [weak self] in self?.sendHue() }
    }

    func setSaturation(_ value: Double) {
        saturation = value
        isOn = true
        isColorMode = true
        colorThrottle.submit { [weak self] in self?.sendHue() }
    }

    private func sendHue() {
        send(LightCommand(state: true, rgb: ColorMath.rgb(hue: hue, saturation: saturation)))
    }

    func applyColor(_ rgb: RGB) {
        hue = ColorMath.hue(of: rgb)
        saturation = ColorMath.saturation(of: rgb)
        isOn = true
        isColorMode = true
        send(LightCommand(state: true, rgb: rgb))
    }

    func applyScene(_ scene: LightScene) {
        send(LightCommand(state: true, sceneId: scene.id, speed: scene.isDynamic ? Int(sceneSpeed.rounded()) : nil))
    }

    func setSceneSpeed(_ value: Double) {
        sceneSpeed = value
        guard let scene = activeScene, scene.isDynamic else { return }
        speedThrottle.submit { [weak self] in self?.sendSceneSpeed() }
    }

    func commitSceneSpeed() {
        guard activeScene?.isDynamic == true else { return }
        speedThrottle.flush { [weak self] in self?.sendSceneSpeed() }
    }

    private func sendSceneSpeed() {
        guard let scene = activeScene else { return }
        send(LightCommand(state: true, sceneId: scene.id, speed: Int(sceneSpeed.rounded())))
    }

    func apply(_ preset: Preset) {
        send(preset.command)
    }

    func adjustBrightness(by delta: Double) {
        setBrightness(min(max(brightness + delta, 10), 100))
        commitBrightness()
    }

    // MARK: Commands

    /// Sends a command to the selected bulb(s) and mirrors it into the UI state.
    func send(_ params: LightCommand) {
        reflect(params)
        guard !targets.isEmpty else {
            if !isDiscovering { Task { await discover() } }
            return
        }
        for bulb in targets { enqueue(params, for: bulb) }
    }

    /// Used by automations: always every bulb, regardless of the menu's bulb picker.
    func sendToAll(_ params: LightCommand) {
        for bulb in bulbs { enqueue(params, for: bulb) }
    }

    private func reflect(_ params: LightCommand) {
        if let state = params.state { isOn = state }
        if let dimming = params.dimming { brightness = Double(dimming) }
        if let temp = params.temp { temperature = Double(temp); isColorMode = false; activeScene = nil }
        if let rgb = params.rgb {
            hue = ColorMath.hue(of: rgb); saturation = ColorMath.saturation(of: rgb)
            isColorMode = true; activeScene = nil
        }
        if let id = params.sceneId { activeScene = availableScenes.first { $0.id == id } }
        if let speed = params.speed { sceneSpeed = Double(speed) }
    }

    /// Queues a command for one bulb, minus anything that bulb can't do.
    private func enqueue(_ params: LightCommand, for bulb: Bulb) {
        guard let params = params.filtered(for: bulb.capabilities) else { return }
        var channel = channels[bulb.id] ?? Channel()
        channel.pending = channel.pending.map { $0.merged(with: params) } ?? params
        channels[bulb.id] = channel
        if !channel.inFlight { drain(bulb) }
    }

    private func drain(_ bulb: Bulb) {
        guard var channel = channels[bulb.id], let params = channel.pending else { return }
        channel.pending = nil
        channel.inFlight = true
        channels[bulb.id] = channel

        Task {
            var failure: Error?
            if let driver = registry.driver(for: bulb) {
                do { try await driver.apply(params, to: bulb) } catch { failure = error }
            } else {
                failure = DriverError.notConfigured("No driver for \(bulb.brand) bulbs.")
            }
            channels[bulb.id]?.inFlight = false
            if let failure {
                record(failure, for: bulb)
            } else {
                offline.remove(bulb.id)
                lastError = nil
            }
            drain(bulb) // anything that arrived while this was in flight
        }
    }

    /// Unreachable bulbs get the driver-specific help card; everything else is a message.
    private func record(_ error: Error, for bulb: Bulb) {
        switch error as? DriverError {
        case .rejected(let reason):
            lastError = "\(bulb.name) rejected the command: \(reason)"
        case .authentication(let message), .notConfigured(let message), .unsupported(let message):
            lastError = "\(bulb.name): \(message)"
        default:
            offline.insert(bulb.id)
        }
    }

    // MARK: State sync

    /// Asks every bulb for its real state so the UI matches it. Called when the menu opens.
    func refresh() async {
        let all = bulbs
        guard !all.isEmpty else { return }

        var states: [String: BulbState] = [:]
        var failed: Set<String> = []
        var problems: [String] = []     // answered, but refused (bad token, driver not set up)
        let registry = self.registry
        await withTaskGroup(of: (Bulb, BulbState?, Error?).self) { group in
            for bulb in all {
                group.addTask {
                    guard let driver = registry.driver(for: bulb) else {
                        return (bulb, nil, DriverError.notConfigured("No driver for \(bulb.brand) bulbs."))
                    }
                    do { return (bulb, try await driver.getState(of: bulb), nil) } catch { return (bulb, nil, error) }
                }
            }
            for await (bulb, state, error) in group {
                if let state {
                    states[bulb.id] = state
                } else {
                    switch error as? DriverError {
                    case .authentication(let m), .notConfigured(let m), .unsupported(let m):
                        problems.append("\(bulb.name): \(m)")      // not a connectivity problem
                    default:
                        failed.insert(bulb.id)
                    }
                }
            }
        }
        if let problem = problems.first { lastError = problem }
        offline = failed
        let shown = targets.compactMap { states[$0.id] }
        if let primary = shown.first(where: { $0.isOn }) ?? shown.first {
            brightness = Double(primary.dimming)
            if let id = primary.sceneId, let scene = availableScenes.first(where: { $0.id == id }) {
                activeScene = scene
                if let speed = primary.speed { sceneSpeed = Double(speed) }
            } else {
                activeScene = nil
            }
            if let kelvin = primary.temperature { temperature = Double(kelvin); isColorMode = false }
            if let rgb = primary.rgb, primary.temperature == nil {
                hue = ColorMath.hue(of: rgb); saturation = ColorMath.saturation(of: rgb); isColorMode = true
            }
        }
        isOn = shown.contains { $0.isOn }

        if shown.isEmpty {
            // The IP may have changed (DHCP); look for them again, at most once a minute.
            if Date().timeIntervalSince(lastDiscovery) > 60 { await discover(quiet: true) }
        } else if problems.isEmpty {
            lastError = nil
        }
    }

    /// Captures every bulb's current state so an automation can put things back afterwards.
    func captureSnapshot() async -> [String: LightCommand] {
        var snapshot: [String: LightCommand] = [:]
        let registry = self.registry
        await withTaskGroup(of: (String, LightCommand?).self) { group in
            for bulb in bulbs {
                group.addTask {
                    guard let driver = registry.driver(for: bulb) else { return (bulb.id, nil) }
                    return (bulb.id, try? await driver.getState(of: bulb).restoreParams())
                }
            }
            for await (id, command) in group { if let command { snapshot[id] = command } }
        }
        return snapshot
    }

    func restore(_ snapshot: [String: LightCommand]) {
        for bulb in bulbs {
            if let params = snapshot[bulb.id] { enqueue(params, for: bulb) }
        }
    }

    // MARK: Bulb management

    func discover(quiet: Bool = false) async {
        guard !isDiscovering else { return }
        isDiscovering = true
        lastDiscovery = Date()
        defer { isDiscovering = false }

        let found = await registry.discoverAll(enabled: enabledDrivers)
        addBulbs(found)
        if found.isEmpty {
            if !quiet { discoveryFoundNothing = true }
        } else {
            discoveryFoundNothing = false
            await refresh()
        }
    }

    /// Adds bulbs, or updates ones already saved (keeping the name the user gave them).
    /// Setup wizards use this too.
    func addBulbs(_ new: [Bulb]) {
        for bulb in new {
            if let index = savedBulbs.firstIndex(where: { $0.id == bulb.id }) {
                savedBulbs[index].address = bulb.address
                savedBulbs[index].capabilities = bulb.capabilities
                savedBulbs[index].native = bulb.native
            } else {
                savedBulbs.append(bulb)
            }
        }
        if !new.isEmpty { discoveryFoundNothing = false }
    }

    /// Adds a bulb by IP, asking every enabled driver that supports it. Returns an error message, or nil on success.
    func addBulb(ip rawIP: String) async -> String? {
        let ip = rawIP.trimmingCharacters(in: .whitespaces)
        guard IPv4Address(ip) != nil else { return "That doesn't look like an IPv4 address." }
        let (bulb, tried) = await registry.probe(host: ip, enabled: enabledDrivers)
        guard let bulb else {
            let advice = tried.map { $0.help.unreachable }.joined(separator: " ")
            return "No bulb answered at \(ip). \(advice)"
        }
        addBulbs([bulb])
        await refresh()
        return nil
    }

    func setDriver(_ id: String, enabled: Bool) {
        if enabled { enabledDrivers.insert(id) } else { enabledDrivers.remove(id) }
        if let selection, !bulbs.contains(where: { $0.id == selection }) { self.selection = nil }
        discoveryFoundNothing = false
        Task { await refresh() }
    }

    /// Test seam: adds a bulb without contacting it.
    func addSavedBulbForTesting(_ bulb: Bulb) { savedBulbs.append(bulb) }

    func remove(_ bulb: Bulb) {
        registry.driver(for: bulb)?.forget(bulb)
        savedBulbs.removeAll { $0.id == bulb.id }
        if selection == bulb.id { selection = nil }
    }

    func rename(_ bulb: Bulb, to name: String) {
        guard let index = savedBulbs.firstIndex(where: { $0.id == bulb.id }) else { return }
        savedBulbs[index].name = name
    }

    func clearError() { lastError = nil }

    // MARK: Hotkeys

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .toggleLight) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        KeyboardShortcuts.onKeyDown(for: .brightnessUp) { [weak self] in
            Task { @MainActor in self?.adjustBrightness(by: 10) }
        }
        KeyboardShortcuts.onKeyDown(for: .brightnessDown) { [weak self] in
            Task { @MainActor in self?.adjustBrightness(by: -10) }
        }
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
