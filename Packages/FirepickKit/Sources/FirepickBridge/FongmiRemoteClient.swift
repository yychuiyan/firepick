import Foundation
import FirepickCore

public struct FongmiRemoteStatus: Decodable, Equatable, Sendable {
    public var active: Bool
    public var title: String?
    public var subtitle: String?
    public var mediaKey: String?
    public var artwork: String?
    public var position: Int64
    public var duration: Int64
    public var state: Int?
    public var playWhenReady: Bool?
    public var repeatOne: Bool?
    public var live: Bool?
    public var canNavigate: Bool?
    public var canSeek: Bool?
    public var canSetSpeed: Bool?
    public var speed: Double?
    public var engine: String?
    public var video: String?

    public init(active: Bool) {
        self.active = active
        position = 0
        duration = 0
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        active = try values.decodeIfPresent(Bool.self, forKey: .active) ?? false
        title = try values.decodeIfPresent(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        mediaKey = try values.decodeIfPresent(String.self, forKey: .mediaKey)
        artwork = try values.decodeIfPresent(String.self, forKey: .artwork)
        position = try values.decodeIfPresent(Int64.self, forKey: .position) ?? 0
        duration = try values.decodeIfPresent(Int64.self, forKey: .duration) ?? 0
        state = try values.decodeIfPresent(Int.self, forKey: .state)
        playWhenReady = try values.decodeIfPresent(Bool.self, forKey: .playWhenReady)
        repeatOne = try values.decodeIfPresent(Bool.self, forKey: .repeatOne)
        live = try values.decodeIfPresent(Bool.self, forKey: .live)
        canNavigate = try values.decodeIfPresent(Bool.self, forKey: .canNavigate)
        canSeek = try values.decodeIfPresent(Bool.self, forKey: .canSeek)
        canSetSpeed = try values.decodeIfPresent(Bool.self, forKey: .canSetSpeed)
        speed = try values.decodeIfPresent(Double.self, forKey: .speed)
        engine = try values.decodeIfPresent(String.self, forKey: .engine)
        video = try values.decodeIfPresent(String.self, forKey: .video)
    }

    private enum CodingKeys: String, CodingKey {
        case active, title, subtitle, mediaKey, artwork, position, duration, state
        case playWhenReady, repeatOne, live, canNavigate, canSeek, canSetSpeed
        case speed, engine, video
    }
}

public enum FongmiRemoteCommand: String, Sendable {
    case play
    case pause
    case stop
    case prev
    case next
    case repeatOn = "repeat_on"
    case repeatOff = "repeat_off"
    case seek
    case speed
}

public actor FongmiRemoteClient {
    public let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func status() async throws -> FongmiRemoteStatus {
        let request = try makeRequest(path: "remote", method: "GET")
        return try await send(request)
    }

    public func control(
        _ command: FongmiRemoteCommand,
        position: Int64 = 0,
        speed: Double = 1
    ) async throws -> FongmiRemoteStatus {
        var values = [URLQueryItem(name: "type", value: command.rawValue)]
        if command == .seek {
            values.append(URLQueryItem(name: "position", value: String(max(0, position))))
        }
        if command == .speed {
            let value = min(5, max(0.1, speed))
            values.append(URLQueryItem(name: "speed", value: String(value)))
        }
        let request = try makeRequest(
            path: "remote",
            method: "POST",
            form: values
        )
        return try await send(request)
    }

    public func deviceInfo() async throws -> [String: String] {
        let request = try makeRequest(path: "remote/info", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?.reduce(into: [:]) { output, item in
            output[item.key] = String(describing: item.value)
        } ?? [:]
    }

    private func makeRequest(
        path: String,
        method: String,
        form: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        let url = path.split(separator: "/").reduce(baseURL) {
            $0.appendingPathComponent(String($1))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            var components = URLComponents()
            components.queryItems = form
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> FongmiRemoteStatus {
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(FongmiRemoteStatus.self, from: data)
        } catch let error as FirepickError {
            throw error
        } catch let error as DecodingError {
            throw FirepickError.bridgeProtocol("FongMi 遥控响应不兼容：\(error.localizedDescription)")
        } catch {
            throw FirepickError.network("FongMi 遥控连接失败：\(error.localizedDescription)")
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FirepickError.bridgeProtocol("无效 FongMi 遥控响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data, as: UTF8.self)
            throw FirepickError.bridgeProtocol("FongMi 遥控 HTTP \(http.statusCode)：\(message)")
        }
    }
}
