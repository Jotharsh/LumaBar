import SwiftUI
import LumaBarCore

/// Setup wizard for one Tuya / Smart Life bulb: device ID, IP address and local key.
struct TuyaSetupView: View {
    @EnvironmentObject private var store: BulbStore
    let driver: TuyaDriver

    @State private var name = ""
    @State private var deviceID = ""
    @State private var host = ""
    @State private var localKey = ""
    @State private var version: TuyaVersion?
    @State private var isWorking = false
    @State private var message: Message?
    @State private var showHelp = false

    private struct Message { let text: String; let isError: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a Tuya bulb").font(.subheadline.weight(.semibold))

            TextField("Name (optional)", text: $name)
            TextField("Device ID", text: $deviceID)
            TextField("IP address (e.g. 192.168.1.50)", text: $host)
            SecureField("Local key (16 characters)", text: $localKey)
            Picker("Protocol version", selection: $version) {
                Text("Auto-detect").tag(TuyaVersion?.none)
                ForEach(TuyaVersion.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)

            HStack {
                Button {
                    add()
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Text("Test & Add Bulb") }
                }
                .disabled(isWorking || deviceID.isEmpty || host.isEmpty || localKey.isEmpty)
                Button("How do I get these?") { showHelp = true }
                    .buttonStyle(.link)
            }

            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(message.isError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The local key is saved in your Mac's Keychain, not in LumaBar's settings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: $showHelp) { TuyaHelpView() }
    }

    private func add() {
        isWorking = true
        message = nil
        Task {
            do {
                let bulb = try await driver.register(deviceID: deviceID, name: name, host: host, localKey: localKey, version: version)
                store.addBulbs([bulb])
                await store.refresh()
                message = Message(text: "Added \(bulb.name) (protocol \(bulb.native["version"] ?? "?")).", isError: false)
                name = ""; deviceID = ""; host = ""; localKey = ""
            } catch {
                var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case .unreachable = error as? DriverError { text += " " + driver.help.unreachable }
                message = Message(text: text, isError: true)
            }
            isWorking = false
        }
    }
}

/// Explains how to get a Tuya bulb's device ID and local key.
struct TuyaHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Getting your Tuya device ID and local key").font(.title3.weight(.semibold))
            Text("Tuya bulbs can be controlled locally, but only with a secret \"local key\" that Tuya doesn't show in the app. You get it once, for free, from a Tuya developer account.")
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(TuyaHelp.keySteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)

            if let url = URL(string: TuyaHelp.guideURL) {
                Link("Step-by-step guide with screenshots (tinytuya)", destination: url)
            }
            Text("Tuya changes its website from time to time, so button names may differ slightly.")
                .font(.caption).foregroundStyle(.secondary)

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }
}
