import Foundation
import ImageIO
import UIKit
import Combine
import UniformTypeIdentifiers

enum CompanionAPIError: LocalizedError {
    case invalidPairingURL
    case insecureEndpoint(URL)
    case endpointOriginMismatch
    case invalidResponse
    case invalidImage
    case server(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPairingURL: return String(localized: "Pairing URL 无效。")
        case .insecureEndpoint: return String(localized: "服务地址必须是完整的 HTTP 或 HTTPS URL。")
        case .endpointOriginMismatch: return String(localized: "服务端端点与 Pairing URL 不属于同一来源。")
        case .invalidResponse: return String(localized: "服务端响应格式无效。")
        case .invalidImage: return String(localized: "图片格式或大小不受支持。")
        case .server(let status, let code, let message):
            if status == 410 || code == "pairing_expired" { return String(localized: "二维码配对已过期，请重新扫码。") }
            if code == "invalid_device_proof" { return String(localized: "此设备无法领取该配对凭据，请重新扫码。") }
            return message
        }
    }

    /// A 401 is not a transient connection failure: callers must discard the
    /// Keychain credential and return to pairing rather than retrying it.
    var invalidatesSessionCredential: Bool {
        if case let .server(status, code, _) = self { return status == 401 || code == "invalid_token" }
        return false
    }

    /// A closed conversation is a shared terminal state, distinct from a
    /// device-only token revocation. The client must return to pairing.
    var closesConversation: Bool {
        if case let .server(_, code, _) = self { return code == "conversation_closed" }
        return false
    }
}

struct BatonAPIClient: Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private static let protectedSession = URLSession(
        configuration: .default,
        delegate: BatonRedirectDelegate(),
        delegateQueue: nil
    )

    /// Media is deliberately isolated from the ordinary API session. Even
    /// when a server permits BatonImageLoader's bounded in-memory cache,
    /// URLSession/URLCache must never retain authenticated image bytes.
    static func mediaSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private static let mediaSession = URLSession(
        configuration: mediaSessionConfiguration(),
        delegate: BatonRedirectDelegate(),
        delegateQueue: nil
    )

    /// Test callers may inject a URLSession. Production requests always use a
    /// session that refuses redirects, so credentials never follow a 3xx hop.
    init(session: URLSession? = nil) { self.session = session ?? Self.protectedSession }

    func createLocalPairing() async throws -> URL {
        let root = URL(string: "http://127.0.0.1:8787")!
        try validateURL(root)
        struct Response: Decodable { let qrURL: URL; enum CodingKeys: String, CodingKey { case qrURL = "qr_url" } }
        let response: Response = try await request(url: root.appending(path: "/v1/baton/pairings"), method: "POST", body: EmptyBody())
        return response.qrURL
    }

    func discover(pairingURL: URL) async throws -> PairingDocument {
        try validateURL(pairingURL)
        let document: PairingDocument = try await get(url: pairingURL)
        guard document.protocolVersion == "baton/1.1" else { throw CompanionAPIError.invalidResponse }
        try validateSameOrigin(pairingURL, document.endpoints.join)
        try validateSameOrigin(pairingURL, document.endpoints.approval)
        try validateSameOrigin(pairingURL, document.endpoints.conversation)
        return document
    }

    func join(_ document: PairingDocument, deviceID: String, deviceName: String, deviceProof: String) async throws -> PendingPairingRequest {
        let request: PendingPairingRequest = try await request(
            url: document.endpoints.join,
            method: "POST",
            body: PairingJoinRequest(deviceID: deviceID, deviceName: deviceName, deviceProof: deviceProof)
        )
        guard request.pairingID == document.pairingID, !request.requestID.isEmpty else {
            throw CompanionAPIError.invalidResponse
        }
        try validateSameOrigin(document.endpoints.join, request.pollURL)
        return request
    }

    func pairingStatus(_ request: PendingPairingRequest, deviceProof: String) async throws -> PairingStatus {
        try validateURL(request.pollURL)
        var urlRequest = URLRequest(url: request.pollURL)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(deviceProof, forHTTPHeaderField: "X-Baton-Device-Proof")
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(status: http.statusCode, data: data) }
        let status = try decoder.decode(PairingStatus.self, from: data)
        guard status.pairingID == request.pairingID, status.requestID == request.requestID else {
            throw CompanionAPIError.invalidResponse
        }
        return status
    }

    func snapshot(endpoint: URL, token: String, timeout: TimeInterval? = nil) async throws -> ConversationSnapshot {
        try await get(url: endpoint, token: token, timeout: timeout)
    }

    func send(endpoint: URL, token: String, text: String, clientMessageID: UUID) async throws -> ConversationMessage {
        struct SendBody: Encodable { let clientMessageID: String; let content: [MessageContent]; enum CodingKeys: String, CodingKey { case clientMessageID = "client_message_id", content } }
        return try await request(url: endpoint.appending(path: "messages"), method: "POST", token: token, body: SendBody(clientMessageID: clientMessageID.uuidString, content: [.text(text)]))
    }

    /// Downloads a server-provided image through the same authenticated,
    /// same-origin boundary as the Conversation itself. Image bytes are never
    /// persisted with credentials or logged.
    func imageData(for image: MessageImage, endpoint: URL, token: String) async throws -> BatonImageResponse {
        guard image.isPlausible, image.url.user == nil, image.url.password == nil else { throw CompanionAPIError.invalidImage }
        try validateSameOrigin(endpoint, image.url)
        var request = URLRequest(url: image.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(image.mimeType, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.mediaSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        let isSuccess = (200...299).contains(http.statusCode)
        let byteLimit = isSuccess ? BatonImageLimits.maximumBytes : 32_768
        var data = Data()
        for try await byte in bytes.prefix(byteLimit + 1) {
            data.append(byte)
            if data.count > byteLimit {
                throw isSuccess ? CompanionAPIError.invalidImage : CompanionAPIError.invalidResponse
            }
        }
        guard isSuccess else { throw decodeServerError(status: http.statusCode, data: data) }
        let responseMIMEType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard data.count <= BatonImageLimits.maximumBytes,
              let responseMIMEType,
              BatonImageFormat.isSupported(responseMIMEType),
              responseMIMEType == image.mimeType.lowercased() else {
            throw CompanionAPIError.invalidImage
        }
        return BatonImageResponse(
            data: data,
            privateCacheLifetime: BatonImageCachePolicy.privateCacheLifetime(
                from: http.value(forHTTPHeaderField: "Cache-Control")
            )
        )
    }

    func cancel(endpoint: URL, token: String, runID: String) async throws {
        struct Response: Decodable {}
        _ = try await request(url: endpoint.appending(path: "runs/\(runID):cancel"), method: "POST", token: token, body: EmptyBody()) as Response
    }

    func endConversation(endpoint: URL, token: String, idempotencyKey: UUID) async throws {
        struct Response: Decodable {}
        guard let endURL = URL(string: endpoint.absoluteString + ":end") else { throw CompanionAPIError.invalidResponse }
        try validateURL(endURL)
        var request = URLRequest(url: endURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try encoder.encode(EmptyBody())
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(status: http.statusCode, data: data) }
        _ = try decoder.decode(Response.self, from: data)
    }

    func events(endpoint: URL, token: String, lastEventID: String?) -> AsyncThrowingStream<BatonEvent, Error> {
        AsyncThrowingStream { continuation in
            let eventsURL = endpoint.appending(path: "events")
            do {
                // Streaming is a network trust boundary too; callers must not
                // bypass the validation performed by snapshot/send requests.
                try validateURL(eventsURL)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            var request = URLRequest(url: eventsURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }

            // AsyncBytes.lines did not deliver flushed SSE frames on the
            // physical-device HTTP fixture. A delegate receives each incoming
            // data callback, so framing remains under Baton’s control.
            let delegate = SSEStreamDelegate(continuation: continuation, decoder: decoder)
            let streamSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = streamSession.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                streamSession.invalidateAndCancel()
            }
            task.resume()
        }
    }

    func revoke(endpoint: URL, token: String, deviceID: String, sessionID: String) async throws {
        // /v1/baton/conversations/{conversationId} → /v1/baton
        let root = endpoint.deletingLastPathComponent().deletingLastPathComponent()
        let revokeURL = root.appending(path: "devices/\(deviceID)/sessions/\(sessionID)")
        try validateURL(revokeURL)
        var request = URLRequest(url: revokeURL)
        request.httpMethod = "DELETE"; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(status: http.statusCode, data: data) }
    }

    private func request<Response: Decodable, Body: Encodable>(url: URL, method: String = "GET", token: String? = nil, body: Body? = nil) async throws -> Response {
        try validateURL(url)
        var request = URLRequest(url: url); request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(status: http.statusCode, data: data) }
        return try decoder.decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(url: URL, token: String? = nil, timeout: TimeInterval? = nil) async throws -> Response {
        try validateURL(url)
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(status: http.statusCode, data: data) }
        return try decoder.decode(Response.self, from: data)
    }

    private func validateURL(_ url: URL) throws {
        guard BatonTransportPolicy.permits(url) else { throw CompanionAPIError.insecureEndpoint(url) }
    }

    private func validateSameOrigin(_ pairingURL: URL, _ endpoint: URL) throws {
        try validateURL(endpoint)
        guard pairingURL.scheme?.lowercased() == endpoint.scheme?.lowercased(), pairingURL.host?.lowercased() == endpoint.host?.lowercased(), pairingURL.port == endpoint.port else { throw CompanionAPIError.endpointOriginMismatch }
    }

    private func decodeServerError(status: Int, data: Data) -> CompanionAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return .server(
            status: status,
            code: error?["code"] as? String,
            message: error?["message"] as? String ?? "请求失败（HTTP \(status)）。"
        )
    }

    private func serverError(response: HTTPURLResponse, bytes: URLSession.AsyncBytes) async throws -> CompanionAPIError {
        var data = Data()
        for try await byte in bytes.prefix(32_768) { data.append(byte) }
        return decodeServerError(status: response.statusCode, data: data)
    }
}

enum BatonImageLimits {
    static let maximumBytes = 12 * 1_024 * 1_024
    static let maximumPixels = 25_000_000
    static let thumbnailMaxPixelSize = 1_600
    static let cacheTotalCostLimit = 80 * 1_024 * 1_024
}

/// A sensitive rendition is non-cacheable unless the service explicitly grants
/// a bounded private lifetime. `no-store` is always authoritative, including
/// for this process's in-memory cache.
enum BatonImageCachePolicy {
    static func privateCacheLifetime(from header: String?) -> TimeInterval? {
        guard let header else { return nil }
        var isPrivate = false
        var forbidsStorage = false
        var maxAge: TimeInterval?

        for rawDirective in header.split(separator: ",") {
            let parts = rawDirective.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch name {
            case "private": isPrivate = true
            case "no-store", "no-cache": forbidsStorage = true
            case "max-age" where parts.count == 2:
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let seconds = TimeInterval(value), seconds > 0 { maxAge = seconds }
            default: break
            }
        }
        guard isPrivate, !forbidsStorage, let maxAge else { return nil }
        return maxAge
    }
}

struct BatonImageResponse {
    let data: Data
    let privateCacheLifetime: TimeInterval?
}

@MainActor
final class BatonImageLoader: ObservableObject {
    private let endpoint: URL
    private let token: String
    private let api: BatonAPIClient
    private let onTerminalFailure: @MainActor () -> Void
    // The media rendition identity survives URL rotation and is the only
    // stable cache key permitted by the Companion Profile.
    private let cache = NSCache<NSString, CachedImage>()

    init(endpoint: URL, token: String, onTerminalFailure: @escaping @MainActor () -> Void = {}) {
        self.endpoint = endpoint
        self.token = token
        self.api = BatonAPIClient()
        self.onTerminalFailure = onTerminalFailure
        cache.countLimit = 40
        cache.totalCostLimit = BatonImageLimits.cacheTotalCostLimit
    }

    init(endpoint: URL, token: String, api: BatonAPIClient, onTerminalFailure: @escaping @MainActor () -> Void = {}) {
        self.endpoint = endpoint
        self.token = token
        self.api = api
        self.onTerminalFailure = onTerminalFailure
        cache.countLimit = 40
        cache.totalCostLimit = BatonImageLimits.cacheTotalCostLimit
    }

    func image(for content: MessageImage) async throws -> UIImage {
        let key = content.mediaID as NSString
        if let cached = cache.object(forKey: key) {
            if cached.expiry > Date() { return cached.image }
            cache.removeObject(forKey: key)
        }
        do {
            let response = try await api.imageData(for: content, endpoint: endpoint, token: token)
            let image = try Self.decodeStaticImage(response.data, declaredMIMEType: content.mimeType)
            let cost = image.cgImage.map { $0.bytesPerRow.multipliedReportingOverflow(by: $0.height) }.flatMap { $0.overflow ? nil : $0.partialValue } ?? BatonImageLimits.cacheTotalCostLimit
            if let lifetime = response.privateCacheLifetime {
                cache.setObject(CachedImage(image: image, expiry: Date().addingTimeInterval(lifetime)), forKey: key, cost: min(cost, BatonImageLimits.cacheTotalCostLimit))
            }
            return image
        } catch {
            if (error as? CompanionAPIError)?.invalidatesSessionCredential == true { onTerminalFailure() }
            throw error
        }
    }

    private final class CachedImage {
        let image: UIImage
        let expiry: Date

        init(image: UIImage, expiry: Date) {
            self.image = image
            self.expiry = expiry
        }
    }

    static func decodeStaticImage(_ data: Data, declaredMIMEType: String) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              sourceMatchesDeclaredMIMEType(source, declaredMIMEType) else {
            throw CompanionAPIError.invalidImage
        }
        let multiplied = width.intValue.multipliedReportingOverflow(by: height.intValue)
        guard width.intValue > 0, height.intValue > 0, !multiplied.overflow,
              multiplied.partialValue <= BatonImageLimits.maximumPixels,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: BatonImageLimits.thumbnailMaxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            throw CompanionAPIError.invalidImage
        }
        return UIImage(cgImage: thumbnail)
    }

    private static func sourceMatchesDeclaredMIMEType(_ source: CGImageSource, _ mimeType: String) -> Bool {
        guard let identifier = CGImageSourceGetType(source) as String? else { return false }
        switch mimeType.lowercased() {
        case "image/jpeg": return identifier == UTType.jpeg.identifier
        case "image/png": return identifier == UTType.png.identifier
        case "image/webp": return identifier == "org.webmproject.webp"
        default: return false
        }
    }
}

private func batonDebugSSE(_ message: String) {
    #if DEBUG
    // Keeps physical-device diagnosis observable without exposing message text,
    // event data, endpoints, or authorization material.
    print("[Baton SSE] \(message)")
    #endif
}

/// Baton endpoint URLs are capabilities. Do not let URLSession forward their
/// authorization headers or pairing proof to a redirect target.
private final class BatonRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
    private let continuation: AsyncThrowingStream<BatonEvent, Error>.Continuation
    private let decoder: JSONDecoder
    private var response: HTTPURLResponse?
    private var lineBuffer = Data()
    private var errorBody = Data()
    private var dataLines: [String] = []
    private var frameID: String?
    private var frameType: String?

    init(continuation: AsyncThrowingStream<BatonEvent, Error>.Continuation, decoder: JSONDecoder) {
        self.continuation = continuation
        self.decoder = decoder
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        batonDebugSSE("redirect_rejected")
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: CompanionAPIError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        self.response = response
        if (200...299).contains(response.statusCode) {
            guard SSEContentType.isEventStream(response.value(forHTTPHeaderField: "Content-Type")) else {
                continuation.finish(throwing: CompanionAPIError.invalidResponse)
                completionHandler(.cancel)
                return
            }
            batonDebugSSE("opened")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let response else { return }
        guard (200...299).contains(response.statusCode) else {
            let remaining = max(0, 32_768 - errorBody.count)
            if remaining > 0 { errorBody.append(data.prefix(remaining)) }
            return
        }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let rawLine = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(...newline)
            guard var line = String(data: rawLine, encoding: .utf8) else {
                continuation.finish(throwing: CompanionAPIError.invalidResponse)
                dataTask.cancel()
                return
            }
            if line.last == "\r" { line.removeLast() }
            if line.isEmpty {
                emitEventIfPresent()
            } else if line.hasPrefix(":") {
                // Standard SSE comments/heartbeats never carry Baton state.
                continue
            } else if let separator = line.firstIndex(of: ":") {
                let field = String(line[..<separator])
                var value = String(line[line.index(after: separator)...])
                if value.first == " " { value.removeFirst() }
                switch field {
                case "id": frameID = value
                case "event": frameType = value
                case "data": dataLines.append(value)
                case "retry": break
                default: batonDebugSSE("unknown_frame_field")
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            batonDebugSSE("failed error=\(type(of: error))")
            continuation.finish(throwing: error)
            return
        }
        guard let response else {
            continuation.finish(throwing: CompanionAPIError.invalidResponse)
            return
        }
        guard (200...299).contains(response.statusCode) else {
            continuation.finish(throwing: decodeServerError(status: response.statusCode, data: errorBody))
            return
        }
        batonDebugSSE("ended")
        continuation.finish()
    }

    private func emitEventIfPresent() {
        defer {
            dataLines.removeAll()
            frameID = nil
            frameType = nil
        }
        guard !dataLines.isEmpty else { return }
        do {
            let event = try SSEEnvelopeDecoder.decode(
                frameID: frameID,
                frameType: frameType,
                data: Data(dataLines.joined(separator: "\n").utf8),
                decoder: decoder
            )
            if !BatonEventType.isKnown(event.type) { batonDebugSSE("unknown_event") }
            batonDebugSSE("received type=\(event.type) sequence=\(event.sequence)")
            continuation.yield(event)
        } catch {
            batonDebugSSE("failed error=\(type(of: error))")
            continuation.finish(throwing: error)
        }
    }

    private func decodeServerError(status: Int, data: Data) -> CompanionAPIError {
        struct ServerError: Decodable { let error: Detail; struct Detail: Decodable { let code: String?; let message: String } }
        if let decoded = try? decoder.decode(ServerError.self, from: data) {
            return .server(status: status, code: decoded.error.code, message: decoded.error.message)
        }
        return .server(status: status, code: nil, message: "服务端请求失败。")
    }
}

enum SSEContentType {
    static func isEventStream(_ value: String?) -> Bool {
        value?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text/event-stream"
    }
}

enum SSEEnvelopeDecoder {
    /// Baton puts the canonical identity both in standard SSE framing and in
    /// its JSON envelope. Reject disagreement rather than letting a proxy or
    /// malformed server silently rewrite resumable stream state.
    static func decode(frameID: String?, frameType: String?, data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> BatonEvent {
        guard let frameID, !frameID.isEmpty, let frameType, !frameType.isEmpty else {
            throw CompanionAPIError.invalidResponse
        }
        let event: BatonEvent
        do {
            event = try decoder.decode(BatonEvent.self, from: data)
        } catch {
            throw CompanionAPIError.invalidResponse
        }
        guard event.id == frameID, event.type == frameType else {
            throw CompanionAPIError.invalidResponse
        }
        return event
    }
}

enum BatonEventType {
    static func isKnown(_ type: String) -> Bool {
        switch type {
        case "conversation.snapshot", "conversation.resync", "conversation.closed",
             "message.created", "message.delta", "message.completed", "message.failed", "message.content.appended",
             "run.started", "run.completed", "run.cancelled":
            true
        default:
            false
        }
    }
}

/// Baton follows the transport selected by the integrating service. HTTP is
/// deliberately supported for legacy/intranet systems; the UI makes it clear
/// that such a connection is unencrypted. Same-origin validation still binds
/// every discovery-provided endpoint to this one selected transport.
enum BatonTransportPolicy {
    static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isEncrypted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }
}

private struct EmptyBody: Encodable {}
