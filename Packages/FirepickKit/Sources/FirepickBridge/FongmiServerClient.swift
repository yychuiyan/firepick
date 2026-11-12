import Foundation
import FirepickCore

/// Client for the production LAN server embedded in FongMi/TV. This adapter is
/// deliberately isolated from Firepick's `/v1` protocol so existing Android
/// installations can serve sources before the standalone Bridge runtime lands.
public actor FongmiServerClient {
    public let baseURL: URL
    private let session: URLSession
    private var spiderSession: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func health() async throws -> String {
        let request = try makeRequest(path: "/device")
        let (data, response) = try await session.data(for: request)
        try validate(response, data)
        return String(decoding: data, as: UTF8.self)
    }

    public func load(
        api: String,
        ext: String,
        jar: String,
        timeout: Int = 30
    ) async throws {
        let sessionId = try await ensureSession()
        let body = LoadBody(api: api, ext: ext, jar: jar, timeout: timeout)
        _ = try await send(
            path: "/spider-api/load",
            method: "POST",
            body: body,
            spiderSession: sessionId
        )
        _ = try await waitUntilIdle(sessionId: sessionId)
    }

    public func invoke(method: String, arguments: [JSONValue]) async throws -> MediaResult {
        guard let spiderSession else {
            throw FirepickError.bridgeProtocol("FongMi Provider 尚未加载")
        }
        let body = RunBody(method: method, args: arguments, timeout: 60)
        _ = try await send(
            path: "/spider-api/run",
            method: "POST",
            body: body,
            spiderSession: spiderSession
        )
        let snapshot = try await waitUntilIdle(sessionId: spiderSession)
        guard snapshot.state == "done" else {
            throw FirepickError.provider(snapshot.result.isEmpty ? snapshot.state : snapshot.result)
        }
        guard let data = snapshot.result.data(using: .utf8) else {
            throw FirepickError.provider("Provider 返回了非 UTF-8 内容")
        }
        if method == ProviderMethod.liveContent.rawValue {
            var result = MediaResult()
            result.rawContent = snapshot.result
            return result
        }
        do {
            return try decoder.decode(MediaResult.self, from: data)
        } catch {
            throw FirepickError.provider("结果 JSON 不兼容：\(error.localizedDescription)")
        }
    }

    public func close() async {
        guard let activeSession = spiderSession else { return }
        if var request = try? makeRequest(path: "/spider-api") {
            request.httpMethod = "DELETE"
            request.setValue(activeSession, forHTTPHeaderField: "x-spider-session")
            _ = try? await session.data(for: request)
        }
        spiderSession = nil
    }

    private func ensureSession() async throws -> String {
        if let spiderSession { return spiderSession }
        var request = try makeRequest(path: "/spider-api")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let data = try await sendData(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let value = object?["session"] as? String else {
            throw FirepickError.bridgeProtocol("FongMi 服务没有返回 spider session")
        }
        spiderSession = value
        return value
    }

    private func waitUntilIdle(sessionId: String) async throws -> Snapshot {
        let deadline = ContinuousClock.now + .seconds(65)
        while ContinuousClock.now < deadline {
            var request = try makeRequest(path: "/spider-api")
            request.setValue(sessionId, forHTTPHeaderField: "x-spider-session")
            let data = try await sendData(request)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            if snapshot.state != "loading" && snapshot.state != "running" {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw FirepickError.provider("FongMi Provider 执行超时")
    }

    private func send<T: Encodable>(
        path: String,
        method: String,
        body: T,
        spiderSession: String
    ) async throws -> Data {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(spiderSession, forHTTPHeaderField: "x-spider-session")
        request.httpBody = try encoder.encode(body)
        return try await sendData(request)
    }

    private func sendData(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data)
            return data
        } catch let error as FirepickError {
            throw error
        } catch {
            throw FirepickError.bridgeUnavailable
        }
    }

    private func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FirepickError.bridgeProtocol("无效 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            throw FirepickError.bridgeProtocol("HTTP \(http.statusCode): \(text)")
        }
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw FirepickError.bridgeProtocol("无效 FongMi 服务地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct LoadBody: Encodable {
        let api: String
        let ext: String
        let jar: String
        let timeout: Int
    }

    private struct RunBody: Encodable {
        let method: String
        let args: [JSONValue]
        let timeout: Int
    }

    private struct Snapshot: Decodable {
        let state: String
        let result: String
    }
}

