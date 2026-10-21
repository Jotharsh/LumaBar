import Foundation

/// Holds every available driver and fans discovery out across the enabled ones.
public final class DriverRegistry: @unchecked Sendable {
    public let drivers: [any BulbDriver]

    public init(drivers: [any BulbDriver]) {
        self.drivers = drivers
    }

    public func driver(id: String) -> (any BulbDriver)? {
        drivers.first { $0.id == id }
    }

    public func driver(for bulb: Bulb) -> (any BulbDriver)? {
        driver(id: bulb.driverID)
    }

    /// Runs discovery on every enabled driver at once and merges the results into one list
    /// (deduplicated by bulb id, ordered by driver then name).
    public func discoverAll(enabled: Set<String>) async -> [Bulb] {
        let active = drivers.filter { enabled.contains($0.id) && $0.isConfigured }
        var merged: [String: Bulb] = [:]
        await withTaskGroup(of: [Bulb].self) { group in
            for driver in active {
                group.addTask { await driver.discover() }
            }
            for await bulbs in group {
                for bulb in bulbs { merged[bulb.id] = bulb }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: drivers.enumerated().map { ($1.id, $0) })
        return merged.values.sorted {
            let a = order[$0.driverID] ?? .max, b = order[$1.driverID] ?? .max
            return a != b ? a < b : $0.name < $1.name
        }
    }

    /// Asks every enabled driver that supports it whether a bulb lives at `host`.
    /// Returns the first match, or the drivers that were tried (for help text) if none answered.
    public func probe(host: String, enabled: Set<String>) async -> (bulb: Bulb?, tried: [any BulbDriver]) {
        let candidates = drivers.filter { enabled.contains($0.id) && $0.supportsManualIP }
        var found: Bulb?
        await withTaskGroup(of: Bulb?.self) { group in
            for driver in candidates {
                group.addTask { try? await driver.probe(host: host) }
            }
            for await bulb in group where found == nil { found = bulb }
        }
        return (found, candidates)
    }
}
