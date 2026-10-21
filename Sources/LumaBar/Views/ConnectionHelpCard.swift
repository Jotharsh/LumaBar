import SwiftUI
import LumaBarCore

/// Explains what to check when no bulb answers. Shown in the menu bar popover and in Settings.
struct ConnectionHelpCard: View {
    @EnvironmentObject private var store: BulbStore
    var showsAddByIP = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.connectionHeadline, systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))

            // When macOS itself is refusing the connection, that is the first thing to fix, whatever the brand.
            if store.systemBlockingSuspected {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS may be blocking LumaBar from your local network.")
                        .font(.caption.weight(.semibold))
                    Text("Open System Settings ▸ Privacy & Security ▸ Local Network and switch LumaBar on (if it's already on, switch it off and on again), then click Try Again.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Local Network Settings") { Self.openLocalNetworkSettings() }
                        .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            // One short, brand-specific instruction per brand involved.
            ForEach(store.connectionHelp, id: \.driverName) { help in
                Text(store.connectionHelp.count > 1 ? "\(help.driverName): \(help.unreachable)" : help.unreachable)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("More things to check") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.connectionHelp, id: \.driverName) { help in
                        ForEach(help.checks, id: \.self) { check in
                            Text("• \(check)").fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Open Privacy Settings") { Self.openLocalNetworkSettings() }
                        .buttonStyle(.link)
                    if let detail = store.connectionDetail {
                        Text("Technical detail: \(detail)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption2)
                .padding(.top, 4)
            }
            .font(.caption)

            HStack {
                Button {
                    Task { store.bulbs.isEmpty ? await store.discover() : await store.refresh() }
                } label: {
                    if store.isDiscovering { ProgressView().controlSize(.small) } else { Text("Try Again") }
                }
                .disabled(store.isDiscovering)
                if !store.bulbs.isEmpty {
                    Button("Search Network") { Task { await store.discover() } }
                        .disabled(store.isDiscovering)
                }
                if showsAddByIP {
                    Button("Add by IP…") { SettingsOpener.open() }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
    }

    private static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}
