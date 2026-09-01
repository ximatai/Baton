import Foundation

/// A durable, read-only replica of one paired Conversation. It intentionally
/// contains no credential or proof: the server remains the only
/// source of truth.
nonisolated struct ConversationLocalStore: Sendable {
    struct CachedSnapshot: Codable {
        let conversation: ConversationDescriptor
        let messages: [ConversationMessage]
        let cursor: EventCursor
    }

    private let conversationKey: String
    private let sessionID: String
    private let lease: UUID

    init(credential: SessionCredential) {
        conversationKey = credential.conversationKey
        sessionID = credential.sessionID
        lease = Self.lifecycle.activate(conversationKey: credential.conversationKey, sessionID: credential.sessionID)
    }

    func loadSnapshot(for credential: SessionCredential) throws -> CachedSnapshot? {
        try withActiveLease {
            guard let data = try readIfPresent(snapshotURL),
                  let snapshot = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
                  snapshot.conversation.id == credential.conversation.id else { return nil }
            return snapshot
        } ?? nil
    }

    func saveSnapshot(conversation: ConversationDescriptor, messages: [ConversationMessage], cursor: EventCursor) throws {
        let data = try JSONEncoder().encode(CachedSnapshot(conversation: conversation, messages: messages, cursor: cursor))
        _ = try withActiveLease { try write(data, to: snapshotURL) }
    }

    func mediaData(for mediaID: String) throws -> Data? {
        try withActiveLease { try readIfPresent(mediaURL(for: mediaID)) } ?? nil
    }

    func saveMedia(_ data: Data, mediaID: String) throws {
        _ = try withActiveLease { try write(data, to: mediaURL(for: mediaID)) }
    }

    func removeMedia(mediaID: String) throws {
        _ = try withActiveLease {
            let url = mediaURL(for: mediaID)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Test/setup helper that clears existing bytes while keeping this active
    /// store lease valid for subsequent writes.
    func removeAll() throws {
        try Self.lifecycle.withExclusive { try removeDirectory() }
    }

    /// Invalidates this exact device-session lease and removes its replica as
    /// one serialized operation. A write that started before this operation
    /// finishes first; every later stale write observes the invalid lease and
    /// cannot recreate the directory. A replacement device session owns a new
    /// lease and is never removed by an older session's cleanup.
    func invalidateAndRemoveAll() throws {
        try Self.lifecycle.invalidateAndPerform(
            conversationKey: conversationKey,
            sessionID: sessionID,
            lease: lease
        ) {
            try removeDirectory()
        }
    }

    private var conversationDirectory: URL {
        Self.rootDirectory.appending(path: Self.safePathComponent(conversationKey), directoryHint: .isDirectory)
    }

    private var snapshotURL: URL { conversationDirectory.appending(path: "snapshot.json") }
    private var mediaDirectory: URL { conversationDirectory.appending(path: "media", directoryHint: .isDirectory) }
    private func mediaURL(for mediaID: String) -> URL { mediaDirectory.appending(path: Self.safePathComponent(mediaID)) }

    private static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Baton", directoryHint: .isDirectory)
            .appending(path: "Conversations", directoryHint: .isDirectory)
    }

    private func withActiveLease<T>(_ operation: () throws -> T) throws -> T? {
        try Self.lifecycle.withActiveLease(
            conversationKey: conversationKey,
            sessionID: sessionID,
            lease: lease,
            operation
        )
    }

    private func removeDirectory() throws {
        let directory = conversationDirectory
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(values)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedFile = url
        try protectedFile.setResourceValues(values)
    }

    private static func safePathComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let lifecycle = ReplicaLifecycle()
}

/// A small synchronous critical section is sufficient here: file I/O is moved
/// off the main actor, while the lock gives deletion and write operations one
/// ordering boundary. It retains only a session ID and an in-memory lease, not
/// any token or other credential material.
nonisolated private final class ReplicaLifecycle: @unchecked Sendable {
    private struct ActiveLease {
        let sessionID: String
        let lease: UUID
    }

    private let lock = NSLock()
    private var activeLeases = [String: ActiveLease]()

    func activate(conversationKey: String, sessionID: String) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let active = activeLeases[conversationKey], active.sessionID == sessionID {
            return active.lease
        }
        let lease = UUID()
        activeLeases[conversationKey] = ActiveLease(sessionID: sessionID, lease: lease)
        return lease
    }

    func withActiveLease<T>(
        conversationKey: String,
        sessionID: String,
        lease: UUID,
        _ operation: () throws -> T
    ) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeases[conversationKey]?.sessionID == sessionID,
              activeLeases[conversationKey]?.lease == lease else { return nil }
        return try operation()
    }

    func invalidateAndPerform(
        conversationKey: String,
        sessionID: String,
        lease: UUID,
        _ operation: () throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard activeLeases[conversationKey]?.sessionID == sessionID,
              activeLeases[conversationKey]?.lease == lease else { return }
        activeLeases.removeValue(forKey: conversationKey)
        try operation()
    }

    func withExclusive(_ operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try operation()
    }
}
