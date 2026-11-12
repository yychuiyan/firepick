import Foundation

public struct VodConfiguration: Codable, Equatable, Sendable {
    public var urls: [ConfigurationDepot]?
    public var spider: String?
    public var sites: [SiteConfiguration]
    public var parses: [ParserConfiguration]?
    public var lives: [LiveConfiguration]?
    public var headers: JSONValue?
    public var doh: JSONValue?
    public var proxy: JSONValue?
    public var rules: JSONValue?
    public var hosts: [String]?
    public var flags: [String]?
    public var ads: [String]?
    public var danmaku: String?
    public var assrt: String?
    public var notice: String?
    public var wallpaper: String?
    public var logo: String?
    public var msg: String?

    public init(
        urls: [ConfigurationDepot]? = nil,
        spider: String? = nil,
        sites: [SiteConfiguration],
        parses: [ParserConfiguration]? = nil,
        lives: [LiveConfiguration]? = nil,
        headers: JSONValue? = nil,
        doh: JSONValue? = nil,
        proxy: JSONValue? = nil,
        rules: JSONValue? = nil,
        hosts: [String]? = nil,
        flags: [String]? = nil,
        ads: [String]? = nil,
        danmaku: String? = nil,
        assrt: String? = nil,
        notice: String? = nil,
        wallpaper: String? = nil,
        logo: String? = nil,
        msg: String? = nil
    ) {
        self.urls = urls
        self.spider = spider
        self.sites = sites
        self.parses = parses
        self.lives = lives
        self.headers = headers
        self.doh = doh
        self.proxy = proxy
        self.rules = rules
        self.hosts = hosts
        self.flags = flags
        self.ads = ads
        self.danmaku = danmaku
        self.assrt = assrt
        self.notice = notice
        self.wallpaper = wallpaper
        self.logo = logo
        self.msg = msg
    }

    public static let empty = VodConfiguration(sites: [])

    public mutating func inheritGlobalSpider(router: SourceRouter = .init()) {
        guard let spider else { return }
        for index in sites.indices
            where sites[index].jar == nil && router.route(sites[index]).runtime == .java {
            sites[index].jar = spider
        }
        if var items = lives {
            for index in items.indices {
                guard items[index].jar == nil,
                      let api = items[index].api else {
                    continue
                }
                let site = SiteConfiguration(
                    key: "live:\(items[index].name)",
                    name: items[index].name,
                    type: 3,
                    api: api
                )
                if router.route(site).runtime == .java {
                    items[index].jar = spider
                }
            }
            lives = items
        }
    }
}

public struct ConfigurationDepot: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
}

public struct ConfigurationDepotDocument: Codable, Equatable, Sendable {
    public var urls: [ConfigurationDepot]
    public var msg: String?
}

public struct SiteConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var name: String
    public var type: Int?
    public var api: String
    public var ext: JSONValue?
    public var jar: String?
    public var click: String?
    public var playUrl: String?
    public var hide: Int?
    public var indexs: Int?
    public var timeout: Int?
    public var searchable: Int?
    public var changeable: Int?
    public var quickSearch: Int?
    public var danmaku: Int?
    public var categories: [String]?
    public var header: JSONValue?
    public var style: SiteStyle?
    public var lang: String?

    public var id: String { key }
    public var effectiveType: Int { type ?? 0 }
    public var isSearchable: Bool { (searchable ?? 1) != 0 }
    public var isQuickSearch: Bool { (quickSearch ?? 1) != 0 }
    public var isHidden: Bool { (hide ?? 0) != 0 }
    public var headerDictionary: [String: String] {
        switch header {
        case let .object(values):
            return values.compactMapValues(\.stringValue)
        case let .string(text):
            guard let data = text.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return values.compactMapValues { $0 as? String }
        default:
            return [:]
        }
    }

    public init(
        key: String,
        name: String,
        type: Int? = 0,
        api: String,
        ext: JSONValue? = nil,
        jar: String? = nil,
        searchable: Int? = 1
    ) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.ext = ext
        self.jar = jar
        self.searchable = searchable
    }
}

public struct SiteStyle: Codable, Equatable, Sendable {
    public var type: String?
    public var ratio: Double?
}

public struct ParserConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var type: Int?
    public var url: String
    public var ext: JSONValue?
}

public struct LiveConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var url: String?
    public var api: String?
    public var ext: JSONValue?
    public var jar: String?
    public var groups: JSONValue?
    public var epg: String?
    public var logo: String?
    public var ua: String?
    public var origin: String?
    public var referer: String?
    public var header: [String: String]?
    public var timeout: Int?
    public var boot: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, url, api, ext, jar, groups, epg, logo, ua, origin, referer
        case header, timeout, boot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "直播源"
        url = try? container.decode(String.self, forKey: .url)
        api = try? container.decode(String.self, forKey: .api)
        ext = try? container.decode(JSONValue.self, forKey: .ext)
        jar = try? container.decode(String.self, forKey: .jar)
        groups = try? container.decode(JSONValue.self, forKey: .groups)
        epg = try? container.decode(String.self, forKey: .epg)
        logo = try? container.decode(String.self, forKey: .logo)
        ua = try? container.decode(String.self, forKey: .ua)
        origin = try? container.decode(String.self, forKey: .origin)
        referer = try? container.decode(String.self, forKey: .referer)
        header = try? container.decode([String: String].self, forKey: .header)
        timeout = try? container.decode(Int.self, forKey: .timeout)
        boot = try? container.decode(Bool.self, forKey: .boot)
    }
}

