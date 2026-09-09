import XCTest
@testable import Baton

/// Opt-in real HTTP coverage for BatonAPIClient.  Run with
/// BATON_INTEGRATION_BASE_URL pointed at a disposable local V1.3 fixture.
@MainActor
final class LiveFixtureIntegrationTests: XCTestCase {
    func testPairUploadCommitAndSnapshotAgainstLiveFixture() async throws {
        guard let value = ProcessInfo.processInfo.environment["BATON_INTEGRATION_BASE_URL"],
              let base = URL(string: value) else {
            throw XCTSkip("Set BATON_INTEGRATION_BASE_URL to run the live fixture integration test.")
        }
        let session = URLSession(configuration: .ephemeral)
        func json(_ url: URL, _ method: String, _ object: Any? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
            var request = URLRequest(url: url); request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            if let object { request.httpBody = try JSONSerialization.data(withJSONObject: object) }
            let (data, response) = try await session.data(for: request)
            XCTAssertTrue((response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let pairing = try await json(base.appending(path: "/v1/baton/pairings"), "POST", [:])
        let pairingID = try XCTUnwrap(pairing["pairing_id"] as? String)
        let discovery = try await json(base.appending(path: "/.well-known/baton/pair/\(pairingID)"), "GET")
        let conversation = try XCTUnwrap((discovery["conversation"] as? [String: Any])?["id"] as? String)
        let proof = "proof_" + UUID().uuidString + UUID().uuidString
        let joined = try await json(base.appending(path: "/v1/baton/pairings/\(pairingID)/requests"), "POST", ["device_id":"ios-live", "device_name":"ios-live", "device_proof":proof])
        _ = try await json(base.appending(path: "/v1/baton/pairings/\(pairingID)/approval"), "POST", ["decision":"approved"])
        let requestID = try XCTUnwrap(joined["request_id"] as? String)
        let credential = try await json(base.appending(path: "/v1/baton/pairings/\(pairingID)/requests/\(requestID)"), "GET", nil, headers:["X-Baton-Device-Proof":proof])
        let token = try XCTUnwrap(credential["access_token"] as? String)
        let endpoint = base.appending(path: "/v1/baton/conversations/\(conversation)")
        let api = BatonAPIClient(session: session, mediaSession: session)
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAABgAAAASCAIAAADOjonJAAAAIklEQVR4nGP8z0AdwEQlcxhGDSIMRg0iDEYNIgxGDWIgCAB9sAEj5CdJegAAAABJRU5ErkJggg==")!
        let staged = try await api.uploadImage(endpoint: endpoint, token: token, data: png, mimeType: "image/png", idempotencyKey: UUID())
        _ = try await api.send(endpoint: endpoint, token: token, content: [.imageReference(staged.mediaID)], clientMessageID: UUID())
        let snapshot = try await api.snapshot(endpoint: endpoint, token: token)
        XCTAssertTrue(snapshot.messages.contains { $0.content.contains { $0.image?.mediaID == staged.mediaID } })
    }
}
