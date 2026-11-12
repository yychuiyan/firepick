import Foundation
import Network
import Darwin
import OSLog

/// Exposes an authenticated or otherwise player-incompatible HTTP stream on a
/// loopback URL without buffering the media file in memory.
public actor LocalMediaProxy {
    public static let shared = LocalMediaProxy()
    private static let logger = Logger(
        subsystem: "app.firepick.core",
        category: "LocalMediaProxy"
    )

    public struct Published: Sendable {
        public let url: URL
        public let token: String
    }

    private struct Target: Sendable {
        let url: URL
        let headers: [String: String]
        let session: URLSession
        let expiresAt: Date
    }

    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var listenerStartTask: Task<UInt16, Error>?
    private var startWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var targets: [String: Target] = [:]

    public init() {}

    public func publish(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession = .shared,
        accessibleOnLAN: Bool = false,
        lifetime: Duration = .seconds(43_200)
    ) async throws -> Published {
        let port = try await ensureStarted()
        removeExpiredTargets()
        let token = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let seconds = max(60, lifetime.components.seconds)
        targets[token] = Target(
            url: url,
            headers: headers,
            session: session,
            expiresAt: .now.addingTimeInterval(TimeInterval(seconds))
        )
        let host = accessibleOnLAN
            ? (LocalNetworkAddress.ipv4() ?? "127.0.0.1")
            : "127.0.0.1"
        guard let localURL = URL(string: "http://\(host):\(port)/stream/\(token)") else {
            throw FirepickError.network("无法创建本地代理地址")
        }
        return Published(url: localURL, token: token)
    }

    private func ensureStarted() async throws -> UInt16 {
        if let listenerPort { return listenerPort }
        if let listenerStartTask {
            return try await listenerStartTask.value
        }
        let task = Task<UInt16, Error> {
            try await self.openListener()
        }
        listenerStartTask = task
        do {
            return try await task.value
        } catch {
            listenerStartTask = nil
            throw error
        }
    }

    private func openListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = false
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task {
                await self?.listenerStateChanged(state)
            }
        }
        listener.start(queue: DispatchQueue(label: "app.firepick.local-proxy"))
        return try await withCheckedThrowingContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else {
                failStart(FirepickError.network("本地代理没有可用端口"))
                return
            }
            listenerPort = port
            listenerStartTask = nil
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume(returning: port) }
        case let .failed(error):
            failStart(FirepickError.network("本地代理启动失败：\(error.localizedDescription)"))
        case .cancelled:
            failStart(FirepickError.network("本地代理已停止"))
        default:
            break
        }
    }

    private func failStart(_ error: Error) {
        listener = nil
        listenerPort = nil
        listenerStartTask = nil
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "app.firepick.local-proxy.connection"))
        Task {
            do {
                let request = try await readRequest(from: connection)
                Self.logger.debug("Local proxy accepted \(request.method, privacy: .public) \(request.target, privacy: .private)")
                try await proxy(request, through: connection)
            } catch {
                Self.logger.error("Local proxy failed: \(error.localizedDescription, privacy: .public)")
                try? await send(
                    errorResponse(
                        status: 502,
                        message: error.localizedDescription
                    ),
                    to: connection
                )
            }
            connection.cancel()
        }
    }

    private func proxy(_ request: HTTPRequest, through connection: NWConnection) async throws {
        guard request.method == "GET" || request.method == "HEAD" else {
            try await send(errorResponse(status: 405, message: "Method Not Allowed"), to: connection)
            return
        }
        let components = request.target.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2, components[0] == "stream" else {
            try await send(errorResponse(status: 404, message: "Not Found"), to: connection)
            return
        }
        removeExpiredTargets()
        guard let target = targets[String(components[1])] else {
            try await send(errorResponse(status: 404, message: "Stream Expired"), to: connection)
            return
        }
        Self.logger.debug("Local proxy target resolved")

        var upstream = URLRequest(url: target.url)
        upstream.httpMethod = request.method
        upstream.timeoutInterval = 30
        target.headers.forEach {
            upstream.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        if let range = request.headers["range"] {
            upstream.setValue(range, forHTTPHeaderField: "Range")
        }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if request.method == "HEAD" {
            let (_, response) = try await target.session.data(for: upstream)
            let http = response as? HTTPURLResponse
            try await send(
                responseHead(
                    status: http?.statusCode ?? 200,
                    headers: forwardedHeaders(http)
                ),
                to: connection
            )
            return
        }

        let (bytes, response) = try await target.session.bytes(for: upstream)
        guard let http = response as? HTTPURLResponse else {
            throw FirepickError.network("上游返回无效响应")
        }
        Self.logger.debug("Local proxy upstream status \(http.statusCode, privacy: .public)")
        try await send(
            responseHead(status: http.statusCode, headers: forwardedHeaders(http)),
            to: connection
        )
        if (200..<300).contains(http.statusCode) {
            var buffer = Data()
            buffer.reserveCapacity(65_536)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 65_536 {
                    try await send(buffer, to: connection)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try await send(buffer, to: connection)
            }
        }
        Self.logger.debug("Local proxy response complete")
    }

    private func removeExpiredTargets() {
        let now = Date()
        targets = targets.filter { $0.value.expiresAt > now }
    }

    private func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try await receive(from: connection)
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= 64 * 1024 else {
                throw FirepickError.network("代理请求头过大")
            }
        }
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            throw FirepickError.network("代理请求格式无效")
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            throw FirepickError.network("代理请求行无效")
        }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: parts[0], target: parts[1], headers: headers)
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func responseHead(status: Int, headers: [String: String]) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason(status))"]
        headers.forEach { lines.append("\($0.key): \($0.value)") }
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func forwardedHeaders(_ response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return ["Content-Type": "application/octet-stream"] }
        let allowed = [
            "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
            "Cache-Control", "ETag", "Last-Modified",
        ]
        var headers: [String: String] = [:]
        for name in allowed {
            if let value = response.value(forHTTPHeaderField: name) {
                headers[name] = value
            }
        }
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/octet-stream"
        }
        return headers
    }

    private func errorResponse(status: Int, message: String) -> Data {
        let body = Data(message.utf8)
        var head = responseHead(
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(body.count),
            ]
        )
        head.append(body)
        return head
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        default: status >= 500 ? "Bad Gateway" : "Proxy Response"
        }
    }
}

private struct HTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
}

private enum LocalNetworkAddress {
    static func ipv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let interface = item.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let end = host.firstIndex(of: 0) ?? host.endIndex
            if status == 0,
               let value = String(validating: host[..<end], as: UTF8.self) {
                return value
            }
        }
        return nil
    }
}
