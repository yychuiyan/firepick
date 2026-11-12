import Foundation
import Testing
@testable import FirepickCore

struct LocalMediaProxyTests {
    @Test
    func streamsRangeThroughLoopbackProxy() async throws {
        let payload = Data((0..<512).map { UInt8($0 % 251) })
        ProxyURLProtocol.handler = { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-511"
            let values = range
                .replacingOccurrences(of: "bytes=", with: "")
                .split(separator: "-")
            let start = Int(values[0]) ?? 0
            let end = values.count > 1 ? Int(values[1]) ?? 511 : 511
            let subset = payload.subdata(in: start..<(end + 1))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Length": String(subset.count),
                    "Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                    "Accept-Ranges": "bytes",
                ]
            )!
            return (response, subset)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyURLProtocol.self]
        let upstreamSession = URLSession(configuration: configuration)
        let proxy = LocalMediaProxy()
        let published = try await proxy.publish(
            url: URL(string: "https://origin.example/media.mp4")!,
            headers: ["Authorization": "Bearer token"],
            session: upstreamSession
        )
        var request = URLRequest(url: published.url)
        request.timeoutInterval = 5
        request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data == payload.subdata(in: 100..<200))
    }
}

private final class ProxyURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: FirepickError.network("missing"))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
