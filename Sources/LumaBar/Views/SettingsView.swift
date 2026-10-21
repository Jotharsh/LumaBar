import SwiftUI
import KeyboardShortcuts
import LumaBarCore

struct SettingsView: View {
    var body: some View {
        TabView {
            BulbsSettings().tabItem { Label("Bulbs", systemImage: "lightbulb") }
            PresetsSettings().tabItem { Label("Presets", systemImage: "sparkles") }
            ShortcutsSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            DriversSettings().tabItem { Label("Drivers", systemImage: "externaldrive.connected.to.line.below") }
            AutomationsSettings().tabItem { Label("Automations", systemImage: "wand.and.stars") }
        }
        .frame(width: 560, height: 540)
    }
}

// MARK: - Bulbs

private struct BulbsSettings: View {
    @EnvironmentObject private var store: BulbStore
    @State private var ip = ""
    @State private var message: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.showConnectionHelp { ConnectionHelpCard(showsAddByIP: false) }
            if store.bulbs.isEmpty {
                Text("No bulbs saved yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(store.bulbs) { bulb in
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(store.offline.contains(bulb.id) ? .red : .green)
                                .help(store.offline.contains(bulb.id) ? "Not responding" : "Online")
                            TextField("Name", text: Binding(get: { bulb.name }, set: { store.rename(bulb, to: $0) }))
                                .textFieldStyle(.plain)
                            Spacer()
                            Text(bulb.brand).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            Text(bulb.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button(role: .destructive) { store.remove(bulb) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 140)
            }

            HStack {
                Button {
                    Task { await store.discover() }
                } label: {
                    if store.isDiscovering { ProgressView().controlSize(.small) } else { Label("Search Network", systemImage: "magnifyingglass") }
                }
                .disabled(store.isDiscovering)
                Text("Finds WiZ bulbs on this Wi-Fi network.").font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            Text("Add by IP address").font(.headline)
            HStack {
                TextField("192.168.1.50", text: $ip)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(add)
                Button("Add", action: add).disabled(ip.isEmpty || adding)
                if adding { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("Find the IP in the WiZ app (bulb ▸ Settings ▸ Device info) or your router. Reserving it in your router keeps it stable.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }

    private func add() {
        adding = true
        message = nil
        Task {
            message = await store.addBulb(ip: ip)
            if message == nil { ip = "" }
            adding = false
        }
    }
}

// MARK: - Presets

private struct PresetsSettings: View {
    @EnvironmentObject private var store: BulbStore
    @State private var selectedID: String?

    private var selectedIndex: Int? { store.presets.firstIndex { $0.id == selectedID } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 8) {
                List(selection: $selectedID) {
                    ForEach(store.presets) { preset in
                        Label(preset.name, systemImage: preset.symbol).tag(preset.id)
                    }
                }
                HStack {
                    Button { addPreset() } label: { Image(systemName: "plus") }
                    Button { deleteSelected() } label: { Image(systemName: "minus") }.disabled(selectedIndex == nil)
                    Spacer()
                    Button("Reset") { store.presets = Preset.defaults; selectedID = nil }
                        .help("Restore the built-in presets")
                }
            }
            .frame(width: 170)

            if let index = selectedIndex {
                editor(for: index)
            } else {
                Text("Select a preset to edit it.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .onAppear { selectedID = selectedID ?? store.presets.first?.id }
    }

    private func editor(for index: Int) -> some View {
        let binding = Binding(get: { store.presets[index] }, set: { store.presets[index] = $0 })
        let useColor = Binding(
            get: { binding.wrappedValue.rgb != nil },
            set: { binding.wrappedValue.rgb = $0 ? ColorMath.rgb(hue: 0.6) : nil })
        let hue = Binding(
            get: { binding.wrappedValue.rgb.map(ColorMath.hue(of:)) ?? 0 },
            set: { binding.wrappedValue.rgb = ColorMath.rgb(hue: $0) })

        return Form {
            TextField("Name", text: binding.name)
            Picker("Icon", selection: binding.symbol) {
                ForEach(["lightbulb", "book", "film", "moon", "scope", "video", "sun.max", "sparkles", "bed.double", "fork.knife", "party.popper"], id: \.self) {
                    Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0)
                }
            }
            Slider(value: Binding(get: { Double(binding.wrappedValue.brightness) }, set: { binding.wrappedValue.brightness = Int($0) }),
                   in: 10...100) { Text("Brightness") } minimumValueLabel: { Text("10") } maximumValueLabel: { Text("100") }
            Toggle("Use a color instead of white", isOn: useColor)
            if useColor.wrappedValue {
                GradientSlider(value: hue, range: 0...1, colors: Color.rainbow)
            } else {
                Slider(value: Binding(get: { Double(binding.wrappedValue.temperature) }, set: { binding.wrappedValue.temperature = Int($0) }),
                       in: 2200...6500) { Text("Warmth") } minimumValueLabel: { Text("2200K") } maximumValueLabel: { Text("6500K") }
                Text("\(binding.wrappedValue.temperature) K").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Try it") { store.apply(binding.wrappedValue) }
                Button("Use current bulb settings") {
                    binding.wrappedValue.brightness = Int(store.brightness)
                    if store.isColorMode { binding.wrappedValue.rgb = ColorMath.rgb(hue: store.hue) }
                    else { binding.wrappedValue.rgb = nil; binding.wrappedValue.temperature = Int(store.temperature) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addPreset() {
        let preset = Preset(name: "New Preset", brightness: 70, temperature: 3000)
        store.presets.append(preset)
        selectedID = preset.id
    }

    private func deleteSelected() {
        guard let index = selectedIndex else { return }
        store.presets.remove(at: index)
        selectedID = store.presets.first?.id
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettings: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Toggle light:", name: .toggleLight)
            KeyboardShortcuts.Recorder("Brightness up:", name: .brightnessUp)
            KeyboardShortcuts.Recorder("Brightness down:", name: .brightnessDown)
            Text("These work from any app. Brightness changes in steps of 10%.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
