import Foundation
import Security

enum KeychainStore {
    private static let service = "net.ximatai.Baton"
    /// Retained only to migrate V1 installations that stored one active session.
    private static let legacySessionAccount = "active-companion-session"
    private static let sessionsAccount = "companion-sessions"
    private static let pendingPairingAccount = "pending-companion-pairing"
    private static let outboxAccount = "pending-conversation-outbox"

    static func loadSessions() throws -> [StoredConversationSession] {
        if let sessions = try load([StoredConversationSession].self, account: sessionsAccount) {
            let normalized = ConversationSessionIndex.deduplicating(sessions)
            if normalized != sessions { try save(normalized, account: sessionsAccount) }
            return normalized
        }
        guard let legacy = try load(SessionCredential.self, account: legacySessionAccount) else { return [] }
        let migrated = [StoredConversationSession(credential: legacy)]
        try save(migrated, account: sessionsAccount)
        delete(account: legacySessionAccount)
        return migrated
    }

    @discardableResult
    static func upsertSession(_ credential: SessionCredential, activatedAt: Date = .now) throws -> [StoredConversationSession] {
        let sessions = ConversationSessionIndex.upserting(credential, into: try loadSessions(), at: activatedAt)
        try save(sessions, account: sessionsAccount)
        return sessions
    }

    @discardableResult
    static func removeConversation(conversationKey: String) throws -> [StoredConversationSession] {
        let sessions = ConversationSessionIndex.removing(conversationKey: conversationKey, from: try loadSessions())
        if sessions.isEmpty { delete(account: sessionsAccount) }
        else { try save(sessions, account: sessionsAccount) }
        return sessions
    }

    @discardableResult
    static func markConversationRead(
        credential: SessionCredential,
        cursor: EventCursor,
        at date: Date = .now
    ) throws -> [StoredConversationSession] {
        let existing = try loadSessions()
        let sessions = ConversationSessionIndex.markingRead(
            for: credential,
            cursor: cursor,
            at: date,
            in: existing
        )
        guard sessions != existing else { return existing }
        try save(sessions, account: sessionsAccount)
        return sessions
    }

    @discardableResult
    static func recordObservedConversationCursor(
        credential: SessionCredential,
        cursor: EventCursor
    ) throws -> [StoredConversationSession] {
        let existing = try loadSessions()
        let sessions = ConversationSessionIndex.recordingObserved(
            for: credential,
            cursor: cursor,
            in: existing
        )
        guard sessions != existing else { return existing }
        try save(sessions, account: sessionsAccount)
        return sessions
    }

    static func savePending(_ credential: PendingPairingCredential) throws {
        try save(credential, account: pendingPairingAccount)
    }

    static func loadPending() throws -> PendingPairingCredential? {
        try load(PendingPairingCredential.self, account: pendingPairingAccount)
    }

    static func deletePending() { delete(account: pendingPairingAccount) }

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
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(insertStatus) }
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
enum KeychainError: LocalizedError { case unexpectedStatus(OSStatus); var errorDescription: String? { String(localized: "无法安全保存本次会话（Keychain 错误）。") } }
