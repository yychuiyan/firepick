import Foundation
import Testing
@testable import FirepickCore
@testable import FirepickPlayback

struct DLNACastTests {
    @Test
    func castsProxiedMediaWithSoapActions() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var actions: [String] = []
        DLNATestURLProtocol.handler = { request in
            if request.url?.host == "origin.example" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": "video/mp4",
                            "Content-Length": "3",
                        ]
                    )!,
                    Data([1, 2, 3])
                )
            }
            let body = requestBody(request)
            lock.lock()
            actions.append(body)
            lock.unlock()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/xml"],
                )!,
                Data("<Envelope/>".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DLNATestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = DLNACastManager(session: session)
        let device = DLNADevice(
            name: "Test TV",
            location: URL(string: "https://renderer.local/device.xml")!,
            controlURL: URL(string: "https://renderer.local/control")!
        )
        try await manager.cast(
            PlaybackRequest(
                url: URL(string: "https://origin.example/video.mp4")!,
                headers: ["Referer": "https://origin.example/"]
            ),
            to: device
        )

        let captured = lock.withLock { actions }
        #expect(captured.count == 2)
        #expect(captured[0].contains("SetAVTransportURI"))
        #expect(captured[0].contains("http://"))
        #expect(captured[0].contains("/stream/"))
        #expect(!captured[0].contains("127.0.0.1"))
        #expect(!captured[0].contains("https://origin.example/video.mp4"))
        #expect(captured[1].contains("<u:Play"))
    }
}

private func requestBody(_ request: URLRequest) -> String {
    if let data = request.httpBody {
        return String(decoding: data, as: UTF8.self)
    }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}

private final class DLNATestURLProtocol: URLProtocol, @unchecked Sendable {
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
