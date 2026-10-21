import SwiftUI
import LumaBarCore

/// Setup for brands that find their own bulbs (Yeelight, LIFX): search, add what's found, or show that brand's help.
struct DiscoverySetupView: View {
    @EnvironmentObject private var store: BulbStore
    let driver: any BulbDriver

    @State private var isSearching = false
    @State private var result: Result?

    private struct Result { let text: String; let isError: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    search()
                } label: {
                    if isSearching { ProgressView().controlSize(.small) } else { Text("Search for \(driver.displayName) bulbs") }
                }
                .disabled(isSearching)
            }
            if let result {
                Label(result.text, systemImage: result.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(result.isError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func search() {
        isSearching = true
        result = nil
        Task {
            let found = await driver.discover()
            if found.isEmpty {
                result = Result(text: "No \(driver.displayName) bulbs found. \(driver.help.unreachable)", isError: true)
            } else {
                store.addBulbs(found)
                await store.refresh()
                result = Result(text: "Found \(found.count) bulb\(found.count == 1 ? "" : "s"): \(found.map(\.name).joined(separator: ", ")).", isError: false)
            }
            isSearching = false
        }
    }
}
