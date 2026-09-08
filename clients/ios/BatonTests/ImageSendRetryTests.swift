import XCTest
@testable import Baton

final class ImageSendRecorder: @unchecked Sendable {
    enum Mode { case timeoutOnce, timeoutThenExpireThenSuccess, holdUpload, holdMessage, expireOnceThenSuccess, expireMessages }
    struct Request { let path: String; let body: Data; let idempotencyKey: String? }

    private let lock = NSLock()
    private var requests = [Request]()
    private var attempts = 0
    private var heldUploadReply: (() -> Void)?
    private var heldMessageReply: (() -> Void)?
    private var mode: Mode = .timeoutOnce
    var expectedSize = 0

    func reset(mode: Mode = .timeoutOnce) {
        lock.lock(); defer { lock.unlock() }
        requests = []; attempts = 0; heldUploadReply = nil; heldMessageReply = nil; self.mode = mode; expectedSize = 0
    }
    func record(_ request: URLRequest, body: Data) {
        lock.lock(); defer { lock.unlock() }
        requests.append(Request(path: request.url!.path, body: body, idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key")))
    }
    func nextMessageAttempt() -> Int { lock.lock(); defer { lock.unlock() }; attempts += 1; return attempts }
    func snapshot() -> [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    func currentMode() -> Mode { lock.lock(); defer { lock.unlock() }; return mode }
    func holdUploadReply(_ reply: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; heldUploadReply = reply }
    func releaseHeldUpload() { lock.lock(); let reply = heldUploadReply; heldUploadReply = nil; lock.unlock(); reply?() }
    func holdMessageReply(_ reply: @escaping () -> Void) { lock.lock(); defer { lock.unlock() }; heldMessageReply = reply }
    func releaseHeldMessage() { lock.lock(); let reply = heldMessageReply; heldMessageReply = nil; lock.unlock(); reply?() }
}
final class ImageSendURLProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder = ImageSendRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if let direct = request.httpBody { body = direct }
        else if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); guard count > 0 else { break }; bytes.append(buffer, count: count) }; body = bytes }
        else { body = Data() }
        Self.recorder.record(request, body: body)
        let path = request.url!.path
        if path.hasSuffix("/media") {
            if Self.recorder.currentMode() == .holdUpload {
                // Keep a real URLSession request in flight.  The test releases
                // its response after suspendActiveConversation has cancelled it.
                Self.recorder.holdUploadReply { self.reply(["media_id":"med_1", "mime_type":"image/png", "width":1, "height":1, "byte_size":Self.recorder.expectedSize, "expires_at":"2030-01-01T00:00:00.000Z"], status: 201) }
                return
            }
            let marker = Data("\r\n\r\n".utf8), tail = Data("\r\n--".utf8)
            let start = body.range(of: marker)?.upperBound ?? body.startIndex
            _ = body.range(of: tail, options: [], in: start..<body.endIndex)?.lowerBound ?? body.endIndex
            reply(["media_id":"med_1", "mime_type":"image/png", "width":1, "height":1, "byte_size":Self.recorder.expectedSize, "expires_at":"2030-01-01T00:00:00.000Z"], status: 201)
        } else if path.hasSuffix("/messages") {
            let attempt = Self.recorder.nextMessageAttempt()
            if (Self.recorder.currentMode() == .timeoutOnce || Self.recorder.currentMode() == .timeoutThenExpireThenSuccess) && attempt == 1 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
            if Self.recorder.currentMode() == .expireMessages ||
                ((Self.recorder.currentMode() == .expireOnceThenSuccess && attempt == 1) ||
                    (Self.recorder.currentMode() == .timeoutThenExpireThenSuccess && attempt == 2)) {
                reply(["error":["code":"media_expired", "message":"staged media expired"]], status: 410)
                return
            }
            if Self.recorder.currentMode() == .holdMessage {
                Self.recorder.holdMessageReply { self.reply(["id":"m1", "conversation_id":"c", "role":"user", "content":[], "created_at":"2026-01-01T00:00:00Z", "status":"completed"], status: 201) }
                return
            }
            reply(["id":"m1", "conversation_id":"c", "role":"user", "content":[["type":"image","media_id":"med_1","url":"https://example.test/v1/baton/media/med_1","mime_type":"image/png","width":1,"height":1,"alt":""]], "created_at":"2026-01-01T00:00:00Z", "status":"completed"], status: 201)
        } else {
            reply(["id":"c","title":"C","messages":[],"selection_states":[],"event_cursor":["id":"e","sequence":1],"active_runs":[]], status: 200)
        }
    }
    private func reply(_ object: Any, status: Int) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ImageSendRetryTests: XCTestCase {
    private let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL3xQAAAABJRU5ErkJggg==")!

    private func makeModel() -> (BatonViewModel, ImageDraftCoordinator, URL) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageSendURLProtocol.self]
        let session = URLSession(configuration: config)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let drafts = ImageDraftCoordinator(root: root)
        let model = BatonViewModel(api: BatonAPIClient(session: session, mediaSession: session), imageDrafts: drafts)
        let credential = makeCredential()
        model.activateForTesting(credential)
        return (model, drafts, root)
    }

    private func makeCredential(conversationID: String = "c") -> SessionCredential {
        SessionCredential(accessToken: "t", deviceID: "d", sessionID: "s", service: ServiceDescriptor(id:"x",name:"x",iconURL:nil), conversation: ConversationDescriptor(id:conversationID,title:"C",agentName:nil), conversationEndpoint: URL(string:"https://example.test/v1/baton/conversations/\(conversationID)")!, imageUploadPolicy: ImageUploadPolicy(maxItemsPerMessage: 1,maxBytesPerItem: 1024,maxPixelsPerItem: 10,mimeTypes:["image/png"]))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock(); let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func importImage(into model: BatonViewModel, drafts: ImageDraftCoordinator) async throws {
        let lease = model.beginPhotoImport(); model.acceptSelectedPhotos([png], lease: lease)
        let imported = await waitUntil { !drafts.drafts.isEmpty }
        XCTAssertTrue(imported)
        ImageSendURLProtocol.recorder.expectedSize = try XCTUnwrap(drafts.drafts.first).byteCount
    }

    func testExpiredPhotoImportLeaseDoesNotCreateDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = ImageDraftCoordinator(root: root)
        let model = BatonViewModel(imageDrafts: drafts)
        let credential = SessionCredential(accessToken:"t", deviceID:"d", sessionID:"s", service:ServiceDescriptor(id:"x",name:"x",iconURL:nil), conversation:ConversationDescriptor(id:"c",title:"C",agentName:nil), conversationEndpoint:URL(string:"https://example.test/v1/baton/conversations/c")!, imageUploadPolicy:ImageUploadPolicy(maxItemsPerMessage:1,maxBytesPerItem:1024,maxPixelsPerItem:10,mimeTypes:["image/png"]))
        model.activateForTesting(credential)
        let lease = model.beginPhotoImport(); model.suspendActiveConversation()
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL3xQAAAABJRU5ErkJggg==")!
        model.acceptSelectedPhotos([png], lease: lease)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(drafts.drafts.isEmpty)
    }
    func testTimeoutRetryReusesExactMessagePayloadWithoutAnotherUpload() async throws {
        ImageSendURLProtocol.recorder.reset()
        let (model, drafts, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try await importImage(into: model, drafts: drafts); model.send()
        let becameUnknown = await waitUntil { model.isMessageOutcomeUnknown }
        XCTAssertTrue(becameUnknown, model.errorMessage ?? "no error")
        let first = try XCTUnwrap(ImageSendURLProtocol.recorder.snapshot().filter { $0.path.hasSuffix("/messages") }.last?.body)
        model.retryUnknownMessage()
        let retryCompleted = await waitUntil { !model.isMessageOutcomeUnknown }
        XCTAssertTrue(retryCompleted)
        let requests = ImageSendURLProtocol.recorder.snapshot()
        let messages = requests.filter { $0.path.hasSuffix("/messages") }
        XCTAssertEqual(messages.count, 2)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: messages[1].body) as? [String: Any])
        XCTAssertEqual(firstObject["client_message_id"] as? String, secondObject["client_message_id"] as? String)
        let content = try XCTUnwrap(secondObject["content"] as? [[String: Any]])
        XCTAssertTrue(content.contains { $0["type"] as? String == "image_ref" && $0["media_id"] as? String == "med_1" })
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/media") }.count, 1)
    }

    func testSuspendingDuringBlockedUploadDoesNotSubmitOrMutateDraftAfterLateReply() async throws {
        ImageSendURLProtocol.recorder.reset(mode: .holdUpload)
        let (model, drafts, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try await importImage(into: model, drafts: drafts)
        let draftID = try XCTUnwrap(drafts.drafts.first).id
        model.composerText = "retain this draft"
        model.send()
        let uploadStarted = await waitUntil { ImageSendURLProtocol.recorder.snapshot().contains { $0.path.hasSuffix("/media") } }
        XCTAssertTrue(uploadStarted)

        model.suspendActiveConversation()
        ImageSendURLProtocol.recorder.releaseHeldUpload()
        try await Task.sleep(for: .milliseconds(100))

        let requests = ImageSendURLProtocol.recorder.snapshot()
        XCTAssertFalse(requests.contains { $0.path.hasSuffix("/messages") })
        XCTAssertEqual(drafts.drafts.map(\.id), [draftID])
        XCTAssertNil(drafts.drafts.first?.stagedMediaID)
        XCTAssertEqual(model.composerText, "retain this draft")
    }

    func testMediaExpiredReuploadsWithNewKeyAndSameMessageIDThenStopsAfterSecondExpiry() async throws {
        ImageSendURLProtocol.recorder.reset(mode: .expireOnceThenSuccess)
        let (model, drafts, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try await importImage(into: model, drafts: drafts)
        model.composerText = "image retry"
        model.send()
        let completed = await waitUntil { !model.isSendingMessage }
        XCTAssertTrue(completed)

        let requests = ImageSendURLProtocol.recorder.snapshot()
        let uploads = requests.filter { $0.path.hasSuffix("/media") }
        let messages = requests.filter { $0.path.hasSuffix("/messages") }
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(messages.count, 2)
        XCTAssertNotEqual(uploads[0].idempotencyKey, uploads[1].idempotencyKey)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: messages[0].body) as? NSDictionary)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: messages[1].body) as? NSDictionary)
        XCTAssertEqual(first["client_message_id"] as? String, second["client_message_id"] as? String)
        XCTAssertEqual(first["content"] as? NSArray, second["content"] as? NSArray, "message JSON must be semantically identical across the re-upload")
        XCTAssertEqual(model.composerText, "")
        XCTAssertTrue(drafts.drafts.isEmpty)

        // A second explicit expiry gets no third attempt.
        ImageSendURLProtocol.recorder.reset(mode: .expireMessages)
        let (retryingModel, retryingDrafts, retryingRoot) = makeModel()
        defer { try? FileManager.default.removeItem(at: retryingRoot) }
        try await importImage(into: retryingModel, drafts: retryingDrafts)
        retryingModel.send()
        let secondExpiry = await waitUntil { ImageSendURLProtocol.recorder.snapshot().filter { $0.path.hasSuffix("/messages") }.count == 2 }
        XCTAssertTrue(secondExpiry)
        try await Task.sleep(for: .milliseconds(100))
        let exhaustedRequests = ImageSendURLProtocol.recorder.snapshot()
        XCTAssertEqual(exhaustedRequests.filter { $0.path.hasSuffix("/media") }.count, 2)
        XCTAssertEqual(exhaustedRequests.filter { $0.path.hasSuffix("/messages") }.count, 2, "a second media_expired response must terminate the retry loop")
        XCTAssertEqual(retryingDrafts.drafts.count, 1)
    }

    func testUnknownRetryRecoversExpiredMediaWithOriginalMessageID() async throws {
        ImageSendURLProtocol.recorder.reset(mode: .timeoutThenExpireThenSuccess)
        let (model, drafts, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try await importImage(into: model, drafts: drafts)
        model.composerText = "retry after timeout"
        model.send()
        let unknown = await waitUntil { model.isMessageOutcomeUnknown }
        XCTAssertTrue(unknown)
        model.retryUnknownMessage()
        let recovered = await waitUntil { !model.isMessageOutcomeUnknown && !model.isSendingMessage }
        XCTAssertTrue(recovered)
        let requests = ImageSendURLProtocol.recorder.snapshot()
        let uploads = requests.filter { $0.path.hasSuffix("/media") }
        let messages = requests.filter { $0.path.hasSuffix("/messages") }
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(messages.count, 3)
        XCTAssertNotEqual(uploads[0].idempotencyKey, uploads[1].idempotencyKey)
        let ids = try messages.map { request -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            return try XCTUnwrap(object["client_message_id"] as? String)
        }
        XCTAssertEqual(Set(ids).count, 1)
    }

    func testCancelledCommitStaysUnknownAndSuspendedRetryCannotMutateDraft() async throws {
        ImageSendURLProtocol.recorder.reset(mode: .holdMessage)
        let (model, drafts, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try await importImage(into: model, drafts: drafts)
        let draftID = try XCTUnwrap(drafts.drafts.first).id
        model.send()
        let commitStarted = await waitUntil { ImageSendURLProtocol.recorder.snapshot().contains { $0.path.hasSuffix("/messages") } }
        XCTAssertTrue(commitStarted)
        model.cancelImageSend()
        XCTAssertTrue(model.isMessageOutcomeUnknown, "cancelling an in-flight commit must synchronously lock the draft")
        ImageSendURLProtocol.recorder.releaseHeldMessage()
        let unknown = await waitUntil { model.isMessageOutcomeUnknown }
        XCTAssertTrue(unknown)
        XCTAssertEqual(drafts.drafts.map(\.id), [draftID])

        // The unknown state locks every draft mutation entrance.
        model.removeSelectedPhoto(id: draftID)
        let lease = model.beginPhotoImport()
        model.acceptSelectedPhotos([png], lease: lease)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(drafts.drafts.map(\.id), [draftID])

        model.suspendActiveConversation()
        model.retryUnknownMessage()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ImageSendURLProtocol.recorder.snapshot().filter { $0.path.hasSuffix("/messages") }.count, 1)
        XCTAssertTrue(model.isMessageOutcomeUnknown)
        XCTAssertEqual(drafts.drafts.map(\.id), [draftID])
    }

    func testSwitchingSessionsClearsOtherSessionsUnknownDraft() async throws {
        ImageSendURLProtocol.recorder.reset(mode: .holdMessage)
        let (model, drafts, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        try await importImage(into: model, drafts: drafts)
        model.composerText = "belongs to c"
        model.send()
        let commitStarted = await waitUntil { ImageSendURLProtocol.recorder.snapshot().contains { $0.path.hasSuffix("/messages") } }
        XCTAssertTrue(commitStarted)
        model.cancelImageSend()
        XCTAssertTrue(model.isMessageOutcomeUnknown)

        model.activateForTesting(makeCredential(conversationID: "other"))
        XCTAssertFalse(model.isMessageOutcomeUnknown)
        XCTAssertFalse(model.isSendingMessage)
        XCTAssertEqual(model.composerText, "")
        XCTAssertTrue(drafts.drafts.isEmpty)
    }
}
