import SwiftUI
import LumaBarCore

/// Connects LumaBar to a Home Assistant server with its address and a long-lived access token.
struct HomeAssistantSetupView: View {
    @EnvironmentObject private var store: BulbStore
    let driver: HomeAssistantDriver

    @State private var url = ""
    @State private var token = ""
    @State private var isConnecting = false
    @State private var connectedURL: String?
    @State private var message: Message?

    private struct Message { let text: String; let isError: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let connectedURL {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Connected to \(connectedURL)").font(.caption)
                    Spacer()
                    Button("Refresh lights") { refresh() }.buttonStyle(.link).font(.caption)
                    Button("Disconnect", role: .destructive) { disconnect() }.buttonStyle(.link).font(.caption)
                }
                Divider()
            }

            Text(connectedURL == nil ? "Connect to Home Assistant" : "Connect to a different server")
                .font(.subheadline.weight(.semibold))
            TextField("Address (e.g. http://homeassistant.local:8123)", text: $url)
                .textFieldStyle(.roundedBorder)
            SecureField("Long-lived access token", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    connect()
                } label: {
                    if isConnecting { ProgressView().controlSize(.small) } else { Text("Connect & Import Lights") }
                }
                .disabled(isConnecting || url.isEmpty || token.isEmpty)
            }
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(message.isError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The token is saved in your Mac's Keychain, not in LumaBar's settings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { connectedURL = driver.isConfigured ? driver.serverURL : nil }
    }

    private func connect() {
        isConnecting = true
        message = nil
        Task {
            do {
                let lights = try await driver.connect(url: url, token: token)
                store.addBulbs(lights)
                await store.refresh()
                connectedURL = driver.serverURL
                message = Message(text: "Connected. Imported \(lights.count) light\(lights.count == 1 ? "" : "s").", isError: false)
                token = ""
            } catch {
                var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case .unreachable = error as? DriverError { text += " " + driver.help.unreachable }
                message = Message(text: text, isError: true)
            }
            isConnecting = false
        }
    }

    private func refresh() {
        Task {
            let lights = await driver.discover()
            store.addBulbs(lights)
            await store.refresh()
            message = Message(text: "Found \(lights.count) light\(lights.count == 1 ? "" : "s").", isError: false)
        }
    }

    private func disconnect() {
        driver.disconnect()
        for bulb in store.savedBulbs where bulb.driverID == HomeAssistantDriver.driverID { store.remove(bulb) }
        connectedURL = nil
        message = nil
    }
}
