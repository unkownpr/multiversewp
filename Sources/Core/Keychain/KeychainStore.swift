import Foundation
import Security

public enum KeychainError: Error, CustomStringConvertible, Sendable {
    case unhandled(OSStatus)
    case unexpectedItemFormat
    case itemNotFound

    public var description: String {
        switch self {
        case .unhandled(let status): "Keychain error: \(status)"
        case .unexpectedItemFormat: "Keychain item has unexpected format"
        case .itemNotFound: "Keychain item not found"
        }
    }
}

public final class KeychainStore: Sendable {

    public static let defaultService: String = "com.semihsilistre.multiversewp.session"

    public let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func setData(_ data: Data, for account: String) throws {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.unhandled(updateStatus) }
        default:
            throw KeychainError.unhandled(addStatus)
        }
    }

    public func setString(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.unexpectedItemFormat }
        try setData(data, for: account)
    }

    public func data(for account: String) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedItemFormat }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func string(for account: String) throws -> String {
        let bytes = try data(for: account)
        guard let value = String(data: bytes, encoding: .utf8) else { throw KeychainError.unexpectedItemFormat }
        return value
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandled(status)
        }
    }

    public func contains(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
