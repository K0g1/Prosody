import Foundation

#if canImport(Security)
import Security
#endif

public enum KeychainStoreError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case operationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The macOS Keychain is unavailable."
        case .operationFailed(let status): return "Keychain operation failed (\(status))."
        }
    }
}

/// Minimal generic-password wrapper for provider secrets. API keys never
/// enter UserDefaults, session manifests, transcript files, or logs.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = AppConstants.bundleIdentifier) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
#if canImport(Security)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
        guard let data = result as? Data else { throw KeychainStoreError.operationFailed(errSecDecode) }
        return String(data: data, encoding: .utf8)
#else
        throw KeychainStoreError.unavailable
#endif
    }

    public func save(_ value: String, account: String) throws {
#if canImport(Security)
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStoreError.operationFailed(status) }
#else
        throw KeychainStoreError.unavailable
#endif
    }

    public func delete(account: String) throws {
#if canImport(Security)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.operationFailed(status)
        }
#else
        throw KeychainStoreError.unavailable
#endif
    }

#if canImport(Security)
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
#endif
}
