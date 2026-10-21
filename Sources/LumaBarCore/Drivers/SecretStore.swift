import Foundation
import Security

/// Where tokens and local keys live. Never UserDefaults, never source code.
public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    /// Passing nil deletes the secret.
    func set(_ value: String?, for key: String) throws
}

public struct SecretStoreError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")"
    }
}

/// Stores secrets as generic passwords in the macOS Keychain, scoped to this app.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "LumaBar") {
        self.service = service
    }

    private func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    public func get(_ key: String) -> String? {
        var request = query(key)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: String) throws {
        guard let value else {
            let status = SecItemDelete(query(key) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw SecretStoreError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw SecretStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw SecretStoreError(status: status)
        }
    }
}

/// For tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func set(_ value: String?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}
