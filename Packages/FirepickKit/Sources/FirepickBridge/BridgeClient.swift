import Foundation
import FirepickCore

public actor BridgeClient {
    public private(set) var credentials: BridgeCredentials
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(credentials: BridgeCredentials) {
        self.credentials = credentials
        session = PinnedURLSession(expectedFingerprint: credentials.certificateSHA256).makeSession()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func health() async throws -> BridgeHealth {
        let request = try makeRequest(path: "/v1/health", method: "GET")
        return try await send(request)
    }

    public func pair(code: String) async throws -> String {
        struct PairRequest: Encodable { let code: String }
        struct PairResponse: Decodable { let token: String }
        let request = try makeRequest(path: "/v1/pair", method: "POST", body: PairRequest(code: code))
        let response: PairResponse = try await send(request, authorized: false)
        credentials.token = response.token
        return response.token
    }

    public func createSession(_ body: BridgeSessionRequest) async throws -> BridgeSessionResponse {
        let request = try makeRequest(path: "/v1/sessions", method: "POST", body: body)
        return try await send(request)
    }

    public func uploadConfiguration(_ configuration: VodConfiguration) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        let digest = ConfigurationDigest.sha256(data)
        var request = try makeRequest(path: "/v1/configs/\(digest)", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FirepickError.bridgeProtocol("配置上传失败")
        }
        return digest
    }

    public func invoke(sessionId: String, request body: BridgeInvokeRequest) async throws -> MediaResult {
        let request = try makeRequest(
            path: "/v1/sessions/\(sessionId)/invoke",
            method: "POST",
            body: body
        )
        return try await send(request)
    }

    public func localProxyURL(
        sessionId: String,
        rawURL: String,
        siteKey: String
    ) async throws -> URL {
        guard let destination = CatVodProxyURL.bridgeURL(
            rawURL,
            baseURL: credentials.baseURL,
            sessionId: sessionId,
            siteKey: siteKey
        ) else {
            throw FirepickError.bridgeProtocol("无法解析 proxy:// 播放地址")
        }
        let published = try await LocalMediaProxy.shared.publish(
            url: destination,
            headers: ["Authorization": "Bearer \(credentials.token)"],
            session: session
        )
        return published.url
    }

    public func deleteSession(id: String) async {
        guard let request = try? makeRequest(path: "/v1/sessions/\(id)", method: "DELETE") else {
            return
        }
        _ = try? await session.data(for: request)
    }

    private func makeRequest<T: Encodable>(
        path: String,
        method: String,
        body: T? = Optional<String>.none
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: credentials.baseURL)?.absoluteURL else {
            throw FirepickError.bridgeProtocol("无效 Bridge 地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, authorized: Bool = true) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FirepickError.bridgeUnavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw FirepickError.bridgeProtocol("无效 HTTP 响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FirepickError.bridgeUnauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode(BridgeErrorEnvelope.self, from: data) {
                throw FirepickError.bridgeProtocol("\(envelope.code): \(envelope.message)")
            }
            throw FirepickError.bridgeProtocol("HTTP \(http.statusCode)")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw FirepickError.bridgeProtocol(error.localizedDescription)
        }
    }
}

