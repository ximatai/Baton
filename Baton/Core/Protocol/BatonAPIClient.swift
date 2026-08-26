import Foundation

enum CompanionAPIError: LocalizedError {
    case invalidPairingURL
    case insecureEndpoint(URL)
    case endpointOriginMismatch
    case invalidResponse
    case server(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPairingURL: return "Pairing URL 无效。"
        case .insecureEndpoint: return "只允许 HTTPS；本地 DEBUG 演示仅允许 127.0.0.1。"
        case .endpointOriginMismatch: return "服务端端点与 Pairing URL 不属于同一来源。"
        case .invalidResponse: return "服务端响应格式无效。"
        case .server(let status, let code, let message):
            if status == 410 || code == "pairing_expired" { return "二维码配对已过期，请重新扫码。" }
            if code == "invalid_device_proof" { return "此设备无法领取该配对凭据，请重新扫码。" }
            return message
        }
    }

    /// A 401 is not a transient connection failure: callers must discard the
    /// Keychain credential and return to pairing rather than retrying it.
    var invalidatesSessionCredential: Bool {
        if case let .server(status, code, _) = self { return status == 401 || code == "invalid_token" }
        return false
    }
}

struct BatonAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) { self.session = session }

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
        guard document.protocolVersion == "baton/1.0" else { throw CompanionAPIError.invalidResponse }
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

    func snapshot(endpoint: URL, token: String) async throws -> ConversationSnapshot {
        try await get(url: endpoint, token: token)
    }

    func send(endpoint: URL, token: String, text: String, clientMessageID: UUID) async throws -> ConversationMessage {
        struct SendBody: Encodable { let clientMessageID: String; let content: [MessageContent]; enum CodingKeys: String, CodingKey { case clientMessageID = "client_message_id", content } }
        return try await request(url: endpoint.appending(path: "messages"), method: "POST", token: token, body: SendBody(clientMessageID: clientMessageID.uuidString, content: [MessageContent(type: "text", text: text)]))
    }

    func cancel(endpoint: URL, token: String, runID: String) async throws {
        struct Response: Decodable {}
        _ = try await request(url: endpoint.appending(path: "runs/\(runID):cancel"), method: "POST", token: token, body: EmptyBody()) as Response
    }

    func events(endpoint: URL, token: String, lastEventID: String?) -> AsyncThrowingStream<BatonEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint.appending(path: "events"))
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
                    guard (200...299).contains(http.statusCode) else { throw try await serverError(response: http, bytes: bytes) }
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            defer { dataLines.removeAll() }
                            guard !dataLines.isEmpty else { continue }
                            let decoded = try decoder.decode(BatonEvent.self, from: Data(dataLines.joined(separator: "\n").utf8))
                            continuation.yield(decoded)
                            continue
                        }
                        if line.hasPrefix("data:") { dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    private func get<Response: Decodable>(url: URL, token: String? = nil) async throws -> Response {
        try validateURL(url)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw decodeServerError(status: http.statusCode, data: data) }
        return try decoder.decode(Response.self, from: data)
    }

    private func validateURL(_ url: URL) throws {
        if url.scheme?.lowercased() == "https" { return }
        #if DEBUG
        if url.scheme?.lowercased() == "http", ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "") { return }
        #endif
        throw CompanionAPIError.insecureEndpoint(url)
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

private struct EmptyBody: Encodable {}
