import Foundation
import Testing
@testable import Baton

@MainActor
struct PairingTests {
    @Test func pairingQRParserAcceptsOnlyAbsoluteURLs() {
        #expect(BatonPairingURLParser.parse("https://service.example/.well-known/baton/pair/abc")?.host == "service.example")
        #expect(BatonPairingURLParser.parse("  http://127.0.0.1:8787/.well-known/baton/pair/abc  ")?.host == "127.0.0.1")
        #expect(BatonPairingURLParser.parse("not a URL") == nil)
        #expect(BatonPairingURLParser.parse("baton://pair/abc") == nil)
        #expect(BatonPairingURLParser.parse("/relative/pairing") == nil)
    }

    @Test func unauthorizedResponseIsTerminalForSavedCredential() {
        let invalid = CompanionAPIError.server(status: 401, code: "invalid_token", message: "expired")
        #expect(invalid.invalidatesSessionCredential)
        #expect(CompanionAPIError.server(status: 401, code: "session_revoked", message: "ended elsewhere").invalidatesSessionCredential)
        #expect(!CompanionAPIError.server(status: 503, code: "temporary", message: "retry").invalidatesSessionCredential)
        #expect(CompanionAPIError.server(status: 410, code: "conversation_closed", message: "ended").closesConversation)
        #expect(!CompanionAPIError.server(status: 410, code: "pairing_expired", message: "expired").closesConversation)
    }

    @Test func transportPolicyAcceptsServiceSelectedHTTPOrHTTPS() {
        let http = URL(string: "http://legacy.example/.well-known/baton/pair/abc")!
        let https = URL(string: "https://service.example/.well-known/baton/pair/abc")!
        #expect(BatonTransportPolicy.permits(http))
        #expect(BatonTransportPolicy.permits(https))
        #expect(!BatonTransportPolicy.permits(URL(string: "baton://pair/abc")!))
        #expect(!BatonTransportPolicy.permits(URL(string: "/relative/pairing")!))
        #expect(!BatonTransportPolicy.isEncrypted(http))
        #expect(BatonTransportPolicy.isEncrypted(https))
    }

    @Test func pairingResponseRejectsRelativePollURL() {
        let json = #"{"pairing_id":"ps_1","request_id":"pr_1","status":"pending","poll_url":"/v1/baton/pairings/ps_1/requests/pr_1","retry_after_seconds":2}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PendingPairingRequest.self, from: Data(json.utf8))
        }
    }

    @Test func pairingApprovalModeDefaultsToManualAndAcceptsServerAutoPolicy() throws {
        let base = #"{"protocol":"baton/1.1","pairing_id":"ps_1","expires_at":"2026-08-30T00:00:00Z","service":{"id":"service","name":"Service"},"conversation":{"id":"conv_1","title":"Conversation"},"endpoints":{"join":"https://service.example/join","approval":"https://service.example/approval","conversation":"https://service.example/conversation"},"capabilities":{"text":true,"image":true,"content_append":true}}"#
        let manual = try JSONDecoder().decode(PairingDocument.self, from: Data(base.utf8))
        #expect(manual.approvalMode == .manual)
        #expect(manual.capabilities.image)
        #expect(manual.capabilities.contentAppend)
        let autoJSON = String(base.dropLast()) + #","approval_mode":"auto"}"#
        let auto = try JSONDecoder().decode(PairingDocument.self, from: Data(autoJSON.utf8))
        #expect(auto.approvalMode == .auto)
    }
}
