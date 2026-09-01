import Foundation

/// A durable, read-only replica of one paired Conversation. It intentionally
/// contains no credential, proof, or outbox item: the server remains the only
/// source of truth and every outgoing request remains Keychain-backed.
nonisolated struct ConversationLocalStore: Sendable {
    struct CachedSnapshot: Codable {
        let conversation: ConversationDescriptor
        let messages: [ConversationMessage]
        let cursor: EventCursor
    }

    private let conversationKey: String

    init(credential: SessionCredential) {
        conversationKey = credential.conversationKey
    }

    func loadSnapshot(for credential: SessionCredential) throws -> CachedSnapshot? {
        guard let data = try readIfPresent(snapshotURL),
              let snapshot = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
              snapshot.conversation.id == credential.conversation.id else { return nil }
        return snapshot
    }

    func saveSnapshot(conversation: ConversationDescriptor, messages: [ConversationMessage], cursor: EventCursor) throws {
        try write(try JSONEncoder().encode(CachedSnapshot(conversation: conversation, messages: messages, cursor: cursor)), to: snapshotURL)
    }

    func mediaData(for mediaID: String) throws -> Data? {
        try readIfPresent(mediaURL(for: mediaID))
    }

    func saveMedia(_ data: Data, mediaID: String) throws {
        try write(data, to: mediaURL(for: mediaID))
    }

    func removeMedia(mediaID: String) throws {
        let url = mediaURL(for: mediaID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func removeAll() throws {
        let directory = conversationDirectory
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
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
}
