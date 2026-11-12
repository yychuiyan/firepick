import Darwin
import Foundation
import FirepickCore

public struct DLNADevice: Identifiable, Equatable, Sendable {
    public var id: String { controlURL.absoluteString }
    public let name: String
    public let location: URL
    public let controlURL: URL

    public init(name: String, location: URL, controlURL: URL) {
        self.name = name
        self.location = location
        self.controlURL = controlURL
    }
}

public actor DLNACastManager {
    public static let shared = DLNACastManager()
    private let serviceType = "urn:schemas-upnp-org:service:AVTransport:1"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func discover(timeout: TimeInterval = 2.5) async throws -> [DLNADevice] {
        let locations = try await Task.detached(priority: .userInitiated) {
            try Self.search(timeout: timeout)
        }.value
        guard !locations.isEmpty else { return [] }

        let describeSession = session
        return await withTaskGroup(of: DLNADevice?.self) { group in
            for location in locations {
                group.addTask {
                    try? await Self.describe(
                        location: location,
                        session: describeSession
                    )
                }
            }
            var found: [DLNADevice] = []
            for await device in group {
                if let device, !found.contains(device) {
                    found.append(device)
                }
            }
            return found.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    public func cast(_ request: PlaybackRequest, to device: DLNADevice) async throws {
        guard request.url.isFileURL == false else {
            throw FirepickError.unsupported("本地文件需要先由设备内的媒体服务器共享")
        }
        let published = try await LocalMediaProxy.shared.publish(
            url: request.url,
            headers: request.headers,
            session: session,
            accessibleOnLAN: true
        )
        let metadata = didl(
            title: request.formatHint ?? request.url.lastPathComponent,
            url: published.url
        )
        try await action(
            device,
            name: "SetAVTransportURI",
            arguments: [
                ("InstanceID", "0"),
                ("CurrentURI", published.url.absoluteString),
                ("CurrentURIMetaData", metadata),
            ]
        )
        try await action(
            device,
            name: "Play",
            arguments: [
                ("InstanceID", "0"),
                ("Speed", "1"),
            ]
        )
    }

    public func control(_ device: DLNADevice, action name: String) async throws {
        try await action(
            device,
            name: name,
            arguments: [("InstanceID", "0")]
        )
    }

    private func action(
        _ device: DLNADevice,
        name: String,
        arguments: [(String, String)]
    ) async throws {
        let body = soapBody(name: name, arguments: arguments)
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"\(serviceType)#\(name)\"",
            forHTTPHeaderField: "SOAPACTION"
        )
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            throw FirepickError.network("DLNA 接收失败：\(text)")
        }
    }

    private func soapBody(
        name: String,
        arguments: [(String, String)]
    ) -> String {
        let values = arguments.map {
            "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(name) xmlns:u="\(serviceType)">\(values)</u:\(name)>
          </s:Body>
        </s:Envelope>
        """
    }

    private func didl(title: String, url: URL) -> String {
        """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="firepick" parentID="0" restricted="1">
            <dc:title>\(xmlEscape(title))</dc:title>
            <upnp:class>object.item.videoItem</upnp:class>
            <res protocolInfo="http-get:*:video/*:*">\(xmlEscape(url.absoluteString))</res>
          </item>
        </DIDL-Lite>
        """
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func search(timeout: TimeInterval) throws -> [URL] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw FirepickError.network("无法创建 DLNA 发现套接字")
        }
        defer { close(descriptor) }

        var receiveTimeout = timeval(
            tv_sec: Int(max(1, Int(timeout))),
            tv_usec: 0
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        destination.sin_addr.s_addr = inet_addr("239.255.255.250")
        let message = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:MediaRenderer:1\r
        \r

        """
        let bytes = Array(message.utf8)
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(
                    descriptor,
                    bytes,
                    bytes.count,
                    0,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard sent == bytes.count else {
            throw FirepickError.network("DLNA 搜索发送失败")
        }

        var locations: [URL] = []
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                continue
            }
            let response = String(decoding: buffer.prefix(count), as: UTF8.self)
            for line in response.components(separatedBy: "\r\n")
                where line.lowercased().hasPrefix("location:") {
                let value = line.split(separator: ":", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: ":")
                    .trimmingCharacters(in: .whitespaces)
                if seen.insert(value).inserted, let url = URL(string: value) {
                    locations.append(url)
                }
            }
        }
        return locations
    }

    private static func describe(
        location: URL,
        session: URLSession
    ) async throws -> DLNADevice? {
        let (data, response) = try await session.data(from: location)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        let delegate = RendererDescriptionDelegate(deviceLocation: location)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(),
              let controlURL = delegate.controlURL else {
            return nil
        }
        return DLNADevice(
            name: delegate.friendlyName.isEmpty ? location.host ?? "DLNA 设备" : delegate.friendlyName,
            location: location,
            controlURL: controlURL
        )
    }
}

private final class RendererDescriptionDelegate: NSObject, XMLParserDelegate {
    private let deviceLocation: URL
    private var currentElement = ""
    private var text = ""
    private var serviceType = ""
    private var serviceControlURL = ""
    private(set) var friendlyName = ""
    private(set) var controlURL: URL?

    init(deviceLocation: URL) {
        self.deviceLocation = deviceLocation
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        text = ""
        if currentElement == "service" {
            serviceType = ""
            serviceControlURL = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "friendlyname" where friendlyName.isEmpty:
            friendlyName = value
        case "servicetype":
            serviceType = value
        case "controlurl":
            serviceControlURL = value
        case "service":
            if serviceType.contains("AVTransport"),
               controlURL == nil,
               let url = URL(string: serviceControlURL, relativeTo: deviceLocation) {
                controlURL = url.absoluteURL
            }
        default:
            break
        }
        currentElement = ""
        text = ""
    }
}
