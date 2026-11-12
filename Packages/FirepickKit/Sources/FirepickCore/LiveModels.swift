import Foundation

public struct LiveGroup: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var password: String?
    public var epg: String?
    public var channels: [LiveChannel]

    public var id: String { name }

    public init(
        name: String,
        password: String? = nil,
        epg: String? = nil,
        channels: [LiveChannel]
    ) {
        self.name = name
        self.password = password
        self.epg = epg
        self.channels = channels
    }

    enum CodingKeys: String, CodingKey {
        case name
        case password = "pass"
        case channels = "channel"
        case epg
    }
}

public struct LiveChannel: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var number: String?
    public var logo: String?
    public var epg: String?
    public var tvgId: String?
    public var urls: [String]
    public var headers: [String: String]

    public var id: String { "\(name)|\(number ?? "")|\(urls.joined(separator: "|"))" }
    public var playableURL: URL? { urls.first.flatMap(URL.init(string:)) }

    public init(
        name: String,
        number: String? = nil,
        logo: String? = nil,
        epg: String? = nil,
        tvgId: String? = nil,
        urls: [String],
        headers: [String: String] = [:]
    ) {
        self.name = name
        self.number = number
        self.logo = logo
        self.epg = epg
        self.tvgId = tvgId
        self.urls = urls
        self.headers = headers
    }

    enum CodingKeys: String, CodingKey {
        case name, number, logo, epg, urls
        case tvgId = "tvgId"
        case headers = "header"
    }
}

public struct LiveConfigurationDocument: Codable, Equatable, Sendable {
    public var lives: [LiveConfiguration]
    public var msg: String?
}

public struct LiveProgram: Codable, Equatable, Identifiable, Sendable {
    public var channelId: String
    public var title: String
    public var description: String?
    public var start: Date
    public var stop: Date

    public var id: String { "\(channelId)|\(start.timeIntervalSince1970)|\(title)" }
}

public enum DetectedConfiguration: Equatable, Sendable {
    case vod(VodConfiguration)
    case depot(ConfigurationDepotDocument)
    case live(name: String, groups: [LiveGroup])
}

