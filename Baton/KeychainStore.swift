import Foundation
import Security

enum KeychainStore {
    private static let service = "net.ximatai.Baton"
    private static let sessionAccount = "active-companion-session"
    private static let pendingPairingAccount = "pending-companion-pairing"
    private static let outboxAccount = "pending-conversation-outbox"

    static func save(_ credential: SessionCredential) throws {
        try save(credential, account: sessionAccount)
    }

    static func load() throws -> SessionCredential? {
        try load(SessionCredential.self, account: sessionAccount)
    }

    static func savePending(_ credential: PendingPairingCredential) throws {
        try save(credential, account: pendingPairingAccount)
    }

    static func loadPending() throws -> PendingPairingCredential? {
        try load(PendingPairingCredential.self, account: pendingPairingAccount)
    }

    static func deletePending() { delete(account: pendingPairingAccount) }
    static func delete() { delete(account: sessionAccount) }

    static func loadOutbox() throws -> [PendingOutboxMessage] {
        try load([PendingOutboxMessage].self, account: outboxAccount) ?? []
    }

    static func saveOutbox(_ messages: [PendingOutboxMessage]) throws {
        if messages.isEmpty { delete(account: outboxAccount) }
        else { try save(messages, account: outboxAccount) }
    }

    static func deleteOutbox() { delete(account: outboxAccount) }

    private static func save<Value: Encodable>(_ value: Value, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, account: String) throws -> Value? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.unexpectedStatus(status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
enum KeychainError: LocalizedError { case unexpectedStatus(OSStatus); var errorDescription: String? { "无法安全保存本次会话（Keychain 错误）。" } }
