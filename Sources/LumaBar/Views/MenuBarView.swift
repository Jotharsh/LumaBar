import SwiftUI
import AppKit
import LumaBarCore

struct MenuBarView: View {
    @EnvironmentObject private var store: BulbStore

    private let swatches: [(String, RGB)] = [
        ("Red", RGB(r: 255, g: 40, b: 40)), ("Orange", RGB(r: 255, g: 140, b: 0)),
        ("Yellow", RGB(r: 255, g: 220, b: 0)), ("Green", RGB(r: 40, g: 220, b: 80)),
        ("Cyan", RGB(r: 0, g: 210, b: 255)), ("Blue", RGB(r: 40, g: 80, b: 255)),
        ("Purple", RGB(r: 170, g: 60, b: 255)), ("Pink", RGB(r: 255, g: 70, b: 170)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if store.showConnectionHelp {
                ConnectionHelpCard()
            }

            if store.bulbs.isEmpty {
                if !store.showConnectionHelp { emptyState }
            } else {
                controls
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { Task { await store.refresh() } }
        // MenuBarExtra's content is created once, so .onAppear only fires the first time it opens.
        // The popover is an NSPanel that becomes key every time it opens; refresh then too.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object is NSPanel { Task { await store.refresh() } }
        }
    }

    // MARK: Pieces

    /// Only the controls the selected bulb(s) support: a white-only bulb gets no colour picker, a plain
    /// dimmable bulb gets no warmth slider, and so on.
    private var controls: some View {
        let caps = store.capabilities
        return VStack(alignment: .leading, spacing: 14) {
            if caps.contains(.power) {
                Toggle(isOn: Binding(get: { store.isOn }, set: { store.setPower($0) })) {
                    Text("Light").font(.body.weight(.medium))
                }
                .toggleStyle(.switch)
            }

            if caps.contains(.brightness) {
                sliderRow(icon: "sun.min", label: "Brightness") {
                    GradientSlider(
                        value: Binding(get: { store.brightness }, set: { store.setBrightness($0) }),
                        range: 10...100,
                        colors: [Color(white: 0.25), Color(white: 0.98)],
                        onEnd: { store.commitBrightness() })
                } trailing: { Text("\(Int(store.brightness))%") }
            }

            if caps.contains(.colorTemp) {
                sliderRow(icon: "thermometer.medium", label: "Warmth") {
                    GradientSlider(
                        value: Binding(get: { store.temperature }, set: { store.setTemperature($0) }),
                        range: 2200...6500,
                        colors: [Color(rgb: 0xFFA23A), Color(rgb: 0xFFE4B5), Color(rgb: 0xFFFFFF), Color(rgb: 0xBFD9FF)],
                        onEnd: { store.commitTemperature() })
                } trailing: { Text("\(Int(store.temperature))K") }
            }

            if caps.contains(.color) { colorSection }
            if caps.contains(.scenes), !store.availableScenes.isEmpty { sceneSection }
            if !caps.intersection([.brightness, .colorTemp, .color]).isEmpty { presetSection }
        }
        .disabled(store.showConnectionHelp)
        .opacity(store.showConnectionHelp ? 0.45 : 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: store.isOn ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(store.isOn ? .yellow : .secondary)
            Text("LumaBar").font(.headline)
            Spacer()
            if store.bulbs.count > 1 {
                Picker("Bulb", selection: Binding(get: { store.selection }, set: { store.selection = $0 })) {
                    Text("All bulbs").tag(String?.none)
                    ForEach(store.bulbs) { bulb in
                        Text(store.offline.contains(bulb.id) ? "\(bulb.name) (offline)" : bulb.name).tag(Optional(bulb.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh from the bulb")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No bulbs yet").font(.body.weight(.medium))
            Text("LumaBar can search your network for WiZ bulbs, or you can add one by its IP address in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task { await store.discover() }
                } label: {
                    if store.isDiscovering { ProgressView().controlSize(.small) } else { Text("Search Network") }
                }
                .disabled(store.isDiscovering)
                Button("Add by IP…") { SettingsOpener.open() }
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Color", systemImage: "paintpalette").font(.caption).foregroundStyle(.secondary)
            GradientSlider(
                value: Binding(get: { store.hue }, set: { store.setHue($0) }),
                range: 0...1,
                colors: Color.rainbow,
                onEnd: { store.commitHue() })
            GradientSlider(
                value: Binding(get: { store.saturation }, set: { store.setSaturation($0) }),
                range: 0...1,
                colors: [.white, Color(hue: store.hue, saturation: 1, brightness: 1)],
                onEnd: { store.commitHue() })
                .help("Saturation")
            HStack(spacing: 6) {
                ForEach(swatches, id: \.0) { name, rgb in
                    Button { store.applyColor(rgb) } label: {
                        Circle().fill(Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name)
                }
            }
        }
    }

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Scenes", systemImage: "theatermasks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let scene = store.activeScene {
                    Text("Running: \(scene.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Menu {
                Section("Animated") {
                    ForEach(store.availableScenes.filter(\.isDynamic)) { sceneButton($0) }
                }
                Section("Static") {
                    ForEach(store.availableScenes.filter { !$0.isDynamic }) { sceneButton($0) }
                }
            } label: {
                Text(store.activeScene?.name ?? "Choose a scene…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let scene = store.activeScene {
                sliderRow(icon: "speedometer", label: "Speed") {
                    GradientSlider(
                        value: Binding(get: { store.sceneSpeed }, set: { store.setSceneSpeed($0) }),
                        range: 10...200,
                        colors: [Color(white: 0.55), .accentColor],
                        onEnd: { store.commitSceneSpeed() })
                        .disabled(!scene.isDynamic)
                        .allowsHitTesting(scene.isDynamic)
                        .opacity(scene.isDynamic ? 1 : 0.35)
                } trailing: {
                    Text(scene.isDynamic ? "\(Int(store.sceneSpeed))%" : "static scene")
                }
            }
        }
    }

    private func sceneButton(_ scene: LightScene) -> some View {
        Button {
            store.applyScene(scene)
        } label: {
            if store.activeScene == scene {
                Label(scene.name, systemImage: "checkmark")
            } else {
                Text(scene.name)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Presets", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(store.presets) { preset in
                    Button { store.apply(preset) } label: {
                        Label(preset.name, systemImage: preset.symbol)
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { SettingsOpener.open() }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.callout)
    }

    private func sliderRow<S: View, T: View>(icon: String, label: String,
                                             @ViewBuilder slider: () -> S,
                                             @ViewBuilder trailing: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Spacer()
                trailing().font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            slider()
        }
    }
}

enum SettingsOpener {
    /// Opens the Settings window. A menu-bar-only app has no menu to trigger it, so send the action directly.
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
