import Foundation
import Testing
@testable import Baton

struct ConversationSessionIndexTests {
    private func credential(
        sessionID: String,
        conversationID: String,
        host: String = "example.test"
    ) -> SessionCredential {
        SessionCredential(
            accessToken: "test-token-\(sessionID)",
            deviceID: "ios_test",
            sessionID: sessionID,
            service: ServiceDescriptor(id: "service", name: "Service", iconURL: nil),
            conversation: ConversationDescriptor(id: conversationID, title: conversationID, agentName: nil),
            conversationEndpoint: URL(string: "https://\(host)/v1/baton/conversations/\(conversationID)")!
        )
    }

    @Test func sessionsAreKeptIndependentlyAndOrderedByLastActivation() {
        let first = credential(sessionID: "session_1", conversationID: "conv_1")
        let second = credential(sessionID: "session_2", conversationID: "conv_2")
        let firstOpened = Date(timeIntervalSince1970: 100)
        let secondOpened = Date(timeIntervalSince1970: 200)

        let afterFirst = ConversationSessionIndex.upserting(first, into: [], at: firstOpened)
        let afterSecond = ConversationSessionIndex.upserting(second, into: afterFirst, at: secondOpened)
        #expect(afterSecond.map(\.id) == [second.conversationKey, first.conversationKey])

        let reactivatedFirst = ConversationSessionIndex.upserting(first, into: afterSecond, at: Date(timeIntervalSince1970: 300))
        #expect(reactivatedFirst.map(\.id) == [first.conversationKey, second.conversationKey])
        #expect(reactivatedFirst.count == 2)

        let remaining = ConversationSessionIndex.removing(conversationKey: first.conversationKey, from: reactivatedFirst)
        #expect(remaining.map(\.id) == [second.conversationKey])
    }

    @Test func aNewDeviceSessionReplacesTheExistingConversationEntry() {
        let original = credential(sessionID: "session_1", conversationID: "conv_1")
        let replacement = credential(sessionID: "session_2", conversationID: "conv_1")

        let originalEntries = ConversationSessionIndex.upserting(original, into: [], at: Date(timeIntervalSince1970: 100))
        let updatedEntries = ConversationSessionIndex.upserting(replacement, into: originalEntries, at: Date(timeIntervalSince1970: 200))

        #expect(updatedEntries.count == 1)
        #expect(updatedEntries.first?.id == original.conversationKey)
        #expect(updatedEntries.first?.credential.sessionID == "session_2")
        #expect(updatedEntries.first?.lastReadCursor == nil)
        #expect(updatedEntries.first?.lastSuccessfulSyncAt == nil)
    }

    @Test func identicalConversationIDsFromDifferentServiceOriginsStaySeparate() {
        let first = credential(sessionID: "session_1", conversationID: "conv_1", host: "one.example.test")
        let second = credential(sessionID: "session_2", conversationID: "conv_1", host: "two.example.test")

        let entries = ConversationSessionIndex.upserting(
            second,
            into: ConversationSessionIndex.upserting(first, into: [], at: Date(timeIntervalSince1970: 100)),
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(entries.count == 2)
        #expect(Set(entries.map(\.id)) == Set([first.conversationKey, second.conversationKey]))
    }

    @Test func readStateIsKeptForTheSameCredentialButIsolatedFromOtherSessions() {
        let first = credential(sessionID: "session_1", conversationID: "conv_1")
        let second = credential(sessionID: "session_2", conversationID: "conv_2")
        let cursor = EventCursor(id: "evt_10", sequence: 10)!
        let syncedAt = Date(timeIntervalSince1970: 100)
        let sessions = ConversationSessionIndex.markingRead(
            for: first,
            cursor: cursor,
            at: syncedAt,
            in: [
                StoredConversationSession(credential: first),
                StoredConversationSession(credential: second)
            ]
        )

        let reactivated = ConversationSessionIndex.upserting(first, into: sessions, at: Date(timeIntervalSince1970: 200))
        let updatedFirst = reactivated.first { $0.credential == first }
        let untouchedSecond = reactivated.first { $0.credential == second }
        #expect(updatedFirst?.lastReadCursor == cursor)
        #expect(updatedFirst?.lastSuccessfulSyncAt == syncedAt)
        #expect(untouchedSecond?.lastReadCursor == nil)
    }

    @Test func availabilityObservationShowsAnUpdateWithoutAdvancingReadState() {
        let saved = credential(sessionID: "session_1", conversationID: "conv_1")
        let read = EventCursor(id: "evt_10", sequence: 10)!
        let observed = EventCursor(id: "evt_12", sequence: 12)!
        let initial = ConversationSessionIndex.markingRead(
            for: saved,
            cursor: read,
            at: Date(timeIntervalSince1970: 100),
            in: [StoredConversationSession(credential: saved)]
        )
        let observedSessions = ConversationSessionIndex.recordingObserved(
            for: saved,
            cursor: observed,
            in: initial
        )
        let summary = ConversationSessionSummary(observedSessions[0])

        #expect(observedSessions[0].lastReadCursor == read)
        #expect(observedSessions[0].lastSuccessfulSyncAt == Date(timeIntervalSince1970: 100))
        #expect(summary.hasUnreadUpdates)
    }

    @Test func localRenameIsIsolatedAndSurvivesAReplacementDeviceSession() {
        let original = credential(sessionID: "session_1", conversationID: "conv_1")
        let other = credential(sessionID: "session_2", conversationID: "conv_2")
        let renamed = ConversationSessionIndex.renamingLocally(
            conversationKey: original.conversationKey,
            to: "现场设备",
            in: [StoredConversationSession(credential: original), StoredConversationSession(credential: other)]
        )
        #expect(ConversationSessionSummary(renamed.first { $0.id == original.conversationKey }!).displayTitle == "现场设备")
        #expect(ConversationSessionSummary(renamed.first { $0.id == other.conversationKey }!).displayTitle == other.conversation.title)

        let replacement = credential(sessionID: "session_3", conversationID: "conv_1")
        let updated = ConversationSessionIndex.upserting(replacement, into: renamed)
        #expect(ConversationSessionSummary(updated.first { $0.id == replacement.conversationKey }!).displayTitle == "现场设备")
    }

    @Test func pinnedSessionsStayAboveRecentSessionsAndSurviveReplacement() {
        let older = credential(sessionID: "session_1", conversationID: "conv_1")
        let newer = credential(sessionID: "session_2", conversationID: "conv_2")
        let initial = [
            StoredConversationSession(credential: older, lastActivatedAt: Date(timeIntervalSince1970: 100)),
            StoredConversationSession(credential: newer, lastActivatedAt: Date(timeIntervalSince1970: 200))
        ]

        let pinned = ConversationSessionIndex.settingPinned(
            conversationKey: older.conversationKey,
            to: true,
            in: initial
        )
        #expect(pinned.map(\.id) == [older.conversationKey, newer.conversationKey])
        #expect(ConversationSessionSummary(pinned[0]).isPinned)

        let replacement = credential(sessionID: "session_3", conversationID: "conv_1")
        let updated = ConversationSessionIndex.upserting(replacement, into: pinned, at: Date(timeIntervalSince1970: 300))
        #expect(updated.first?.id == replacement.conversationKey)
        #expect(updated.first?.isPinned == true)

        let unpinned = ConversationSessionIndex.settingPinned(
            conversationKey: replacement.conversationKey,
            to: false,
            in: updated
        )
        #expect(unpinned.map(\.id) == [replacement.conversationKey, newer.conversationKey])
    }

    @Test func legacyStoredSessionDecodesWithAnUnknownReadBaseline() throws {
        let original = StoredConversationSession(
            credential: credential(sessionID: "session_1", conversationID: "conv_1"),
            lastActivatedAt: Date(timeIntervalSince1970: 100)
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "lastReadCursor")
        object.removeValue(forKey: "lastSuccessfulSyncAt")
        object.removeValue(forKey: "latestObservedCursor")
        object.removeValue(forKey: "isPinned")
        var credentialObject = try #require(object["credential"] as? [String: Any])
        credentialObject.removeValue(forKey: "canEndConversation")
        object["credential"] = credentialObject
        let decoded = try JSONDecoder().decode(
            StoredConversationSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.credential == original.credential)
        #expect(decoded.lastReadCursor == nil)
        #expect(decoded.lastSuccessfulSyncAt == nil)
        #expect(decoded.latestObservedCursor == nil)
        #expect(!decoded.isPinned)
        #expect(!decoded.credential.canEndConversation)
        #expect(!ConversationSessionSummary(decoded).hasUnreadUpdates)
    }

    @Test func suspendedOrReplacedSessionCannotAcceptAnInFlightSnapshot() {
        let first = credential(sessionID: "session_1", conversationID: "conv_1")
        let replacement = credential(sessionID: "session_2", conversationID: "conv_1")

        #expect(!ConversationSessionSyncValidity.acceptsSnapshot(
            for: first,
            activeCredential: first,
            maintainsConnection: false,
            isTaskCancelled: false
        ))
        #expect(!ConversationSessionSyncValidity.acceptsSnapshot(
            for: first,
            activeCredential: replacement,
            maintainsConnection: true,
            isTaskCancelled: false
        ))
        #expect(!ConversationSessionSyncValidity.acceptsSnapshot(
            for: first,
            activeCredential: first,
            maintainsConnection: true,
            isTaskCancelled: true
        ))
        #expect(ConversationSessionSyncValidity.acceptsSnapshot(
            for: first,
            activeCredential: first,
            maintainsConnection: true,
            isTaskCancelled: false
        ))
    }
}
