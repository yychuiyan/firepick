import Foundation
import FirepickCore

public struct BridgeCredentials: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var certificateSHA256: String
    public var token: String

    public init(baseURL: URL, certificateSHA256: String, token: String) {
        self.baseURL = baseURL
        self.certificateSHA256 = certificateSHA256.lowercased()
        self.token = token
    }
}

public struct BridgePairingPayload: Equatable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var certificateSHA256: String
    public var code: String

    public init?(_ url: URL) {
        guard url.scheme == "firepick",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let bridgeURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let parsedURL = URL(string: bridgeURL),
              let fingerprint = components.queryItems?.first(where: { $0.name == "pin" })?.value,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        self.id = components.queryItems?.first(where: { $0.name == "id" })?.value ?? UUID().uuidString
        self.name = components.queryItems?.first(where: { $0.name == "name" })?.value ?? "Firepick Bridge"
        self.baseURL = parsedURL
        self.certificateSHA256 = fingerprint.lowercased()
        self.code = code
    }
}

public struct BridgeHealth: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var bridgeVersion: String
    public var configDigest: String?
    public var runtimes: [ProviderRuntime]
    public var available: Bool

    public init(
        protocolVersion: Int,
        bridgeVersion: String,
        configDigest: String?,
        runtimes: [ProviderRuntime],
        available: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.bridgeVersion = bridgeVersion
        self.configDigest = configDigest
        self.runtimes = runtimes
        self.available = available
    }
}

public struct BridgeSessionRequest: Codable, Sendable {
    public var configDigest: String
    public var source: SiteConfiguration
    public var timeoutSeconds: Int

    public init(configDigest: String, source: SiteConfiguration, timeoutSeconds: Int = 20) {
        self.configDigest = configDigest
        self.source = source
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BridgeSessionResponse: Codable, Sendable {
    public var sessionId: String
    public var expiresAt: Date
}

public struct BridgeInvokeRequest: Codable, Sendable {
    public var method: ProviderMethod
    public var arguments: [JSONValue]

    public init(method: ProviderMethod, arguments: [JSONValue]) {
        self.method = method
        self.arguments = arguments
    }
}

public struct BridgeErrorEnvelope: Codable, Error, Equatable, Sendable {
    public var code: String
    public var message: String
}

