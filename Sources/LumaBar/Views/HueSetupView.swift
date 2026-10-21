import SwiftUI
import LumaBarCore

/// Hue setup: find the bridge, press its link button, pair. LumaBar then adds the bridge's lights.
struct HueSetupView: View {
    @EnvironmentObject private var store: BulbStore
    let driver: HueDriver

    @State private var bridges: [HueBridge] = []
    @State private var paired: [HueBridge] = []
    @State private var manualHost = ""
    @State private var selected: HueBridge?
    @State private var isFinding = false
    @State private var isPairing = false
    @State private var message: Message?

    private struct Message { let text: String; let isError: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !paired.isEmpty {
                Text("Paired bridges").font(.subheadline.weight(.semibold))
                ForEach(paired) { bridge in
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("\(bridge.name) (\(bridge.host))")
                        Spacer()
                        Button("Refresh lights") { refreshLights(of: bridge) }.buttonStyle(.link)
                        Button("Unpair", role: .destructive) { unpair(bridge) }.buttonStyle(.link)
                    }
                    .font(.caption)
                }
                Divider()
            }

            Text("Pair a bridge").font(.subheadline.weight(.semibold))
            HStack {
                Button { find(viaPhilips: false) } label: {
                    if isFinding { ProgressView().controlSize(.small) } else { Text("Find Bridges") }
                }
                .disabled(isFinding || isPairing)
                Button("Use Philips' online lookup") { find(viaPhilips: true) }
                    .buttonStyle(.link)
                    .help("Asks Philips' servers which bridges are on your network. Needs the internet.")
                    .disabled(isFinding || isPairing)
            }

            ForEach(bridges) { bridge in
                Button {
                    selected = bridge
                    manualHost = bridge.host
                } label: {
                    HStack {
                        Image(systemName: selected == bridge ? "largecircle.fill.circle" : "circle")
                        Text("\(bridge.name) (\(bridge.host))")
                    }
                }
                .buttonStyle(.plain)
            }

            HStack {
                TextField("Bridge IP address (e.g. 192.168.1.2)", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                Button {
                    pair()
                } label: {
                    if isPairing { ProgressView().controlSize(.small) } else { Text("Pair") }
                }
                .disabled(manualHost.isEmpty || isPairing || isFinding)
            }

            if isPairing {
                Label("Press the large round link button on top of your Hue Bridge now. LumaBar waits up to 30 seconds.", systemImage: "hand.tap")
                    .font(.caption).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(message.isError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { paired = driver.book.all }
    }

    private func find(viaPhilips: Bool) {
        isFinding = true
        message = nil
        Task {
            bridges = viaPhilips ? await driver.findBridgesViaPhilips() : await driver.findBridges()
            if bridges.isEmpty {
                message = Message(text: "No bridge found. \(driver.help.unreachable) You can also type its IP address (find it in your router's device list or the Hue app's bridge settings).", isError: true)
            } else if bridges.count == 1 {
                selected = bridges[0]; manualHost = bridges[0].host
            }
            isFinding = false
        }
    }

    private func pair() {
        isPairing = true
        message = nil
        Task {
            do {
                let bridge = try await driver.pair(host: manualHost.trimmingCharacters(in: .whitespaces))
                let lights = try await driver.lights(on: bridge)
                store.addBulbs(lights)
                await store.refresh()
                paired = driver.book.all
                message = Message(text: "Paired with \(bridge.name) and added \(lights.count) light\(lights.count == 1 ? "" : "s").", isError: false)
                manualHost = ""; bridges = []; selected = nil
            } catch {
                var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case .unreachable = error as? DriverError { text += " " + driver.help.unreachable }
                message = Message(text: text, isError: true)
            }
            isPairing = false
        }
    }

    private func refreshLights(of bridge: HueBridge) {
        Task {
            do {
                let lights = try await driver.lights(on: bridge)
                store.addBulbs(lights)
                await store.refresh()
                message = Message(text: "Found \(lights.count) light\(lights.count == 1 ? "" : "s") on \(bridge.name).", isError: false)
            } catch {
                message = Message(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
            }
        }
    }

    private func unpair(_ bridge: HueBridge) {
        driver.unpair(bridge)
        for bulb in store.savedBulbs where bulb.native["bridge"] == bridge.id { store.remove(bulb) }
        paired = driver.book.all
    }
}
