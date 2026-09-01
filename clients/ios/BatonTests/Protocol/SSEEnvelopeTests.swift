import Foundation
import Testing
@testable import Baton

@MainActor
struct SSEEnvelopeTests {
    private let validData = Data(#"{"id":"evt_11","sequence":11,"type":"message.delta","data":{"message_id":"msg_1","delta":"hello"}}"#.utf8)

    @Test func acceptsMatchingSSEFrameAndBatonEnvelope() throws {
        let event = try SSEEnvelopeDecoder.decode(frameID: "evt_11", frameType: "message.delta", data: validData)
        #expect(event.id == "evt_11")
        #expect(event.type == "message.delta")
    }

    @Test func rejectsMismatchedSSEIdentityOrType() {
        assertInvalidResponse { try SSEEnvelopeDecoder.decode(frameID: "evt_other", frameType: "message.delta", data: validData) }
        assertInvalidResponse { try SSEEnvelopeDecoder.decode(frameID: "evt_11", frameType: "run.started", data: validData) }
    }

    @Test func acceptsOnlyEventStreamMIMEType() {
        #expect(SSEContentType.isEventStream("text/event-stream"))
        #expect(SSEContentType.isEventStream("text/event-stream; charset=utf-8"))
        #expect(!SSEContentType.isEventStream("application/json"))
        #expect(!SSEContentType.isEventStream(nil))
    }

    @Test func recognizesV11ContentAppendEvents() {
        #expect(BatonEventType.isKnown("message.content.appended"))
        #expect(!BatonEventType.isKnown("message.content.replaced"))
    }

    @Test func imageRequestsCannotUseSystemURLCache() {
        let configuration = BatonAPIClient.mediaSessionConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func rejectsMissingZeroAndNegativeEventSequences() {
        let missing = Data(#"{"id":"evt_11","type":"message.delta","data":{}}"#.utf8)
        let zero = Data(#"{"id":"evt_11","sequence":0,"type":"message.delta","data":{}}"#.utf8)
        let negative = Data(#"{"id":"evt_11","sequence":-1,"type":"message.delta","data":{}}"#.utf8)
        for data in [missing, zero, negative] {
            assertInvalidResponse { try SSEEnvelopeDecoder.decode(frameID: "evt_11", frameType: "message.delta", data: data) }
        }
    }

    private func assertInvalidResponse(_ operation: () throws -> BatonEvent) {
        do {
            _ = try operation()
            Issue.record("Expected an invalid SSE envelope to be rejected.")
        } catch let error as CompanionAPIError {
            guard case .invalidResponse = error else {
                Issue.record("Expected invalidResponse, received a different API error.")
                return
            }
        } catch {
            Issue.record("Expected CompanionAPIError.invalidResponse.")
        }
    }
}
