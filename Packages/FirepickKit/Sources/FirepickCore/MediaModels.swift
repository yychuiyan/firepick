import Foundation

public struct Category: Codable, Equatable, Identifiable, Sendable {
    public var typeId: String
    public var typeName: String
    public var typeFlag: String?
    public var filters: JSONValue?

    public var id: String { typeId }

    public init(
        typeId: String,
        typeName: String,
        typeFlag: String? = nil,
        filters: JSONValue? = nil
    ) {
        self.typeId = typeId
        self.typeName = typeName
        self.typeFlag = typeFlag
        self.filters = filters
    }

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
        case typeFlag = "type_flag"
        case filters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typeId = try container.flexibleString(forKey: .typeId)
        typeName = try container.flexibleString(forKey: .typeName)
        typeFlag = try container.flexibleStringIfPresent(forKey: .typeFlag)
        filters = try container.decodeIfPresent(JSONValue.self, forKey: .filters)
    }
}

public struct MediaItem: Codable, Equatable, Identifiable, Sendable {
    public var vodId: String
    public var name: String
    public var typeName: String?
    public var pic: String?
    public var remarks: String?
    public var year: String?
    public var area: String?
    public var director: String?
    public var actor: String?
    public var content: String?
    public var playFrom: String?
    public var playURL: String?
    public var playId: String?
    public var tag: String?
    public var action: String?
    public var style: SiteStyle?
    public var land: Int?
    public var circle: Int?
    public var ratio: Double?
    /// Locally attached origin. It is intentionally excluded from the custom
    /// CatVod wire encoding below.
    public var sourceKey: String? = nil
    public var isFolder: Bool { tag == "folder" }
    public var isAction: Bool { !(action ?? "").isEmpty }

    public var id: String { vodId }

    public init(
        vodId: String,
        name: String,
        typeName: String? = nil,
        pic: String? = nil,
        remarks: String? = nil,
        year: String? = nil,
        area: String? = nil,
        director: String? = nil,
        actor: String? = nil,
        content: String? = nil,
        playFrom: String? = nil,
        playURL: String? = nil,
        playId: String? = nil,
        tag: String? = nil,
        action: String? = nil,
        style: SiteStyle? = nil,
        land: Int? = nil,
        circle: Int? = nil,
        ratio: Double? = nil,
        sourceKey: String? = nil
    ) {
        self.vodId = vodId
        self.name = name
        self.typeName = typeName
        self.pic = pic
        self.remarks = remarks
        self.year = year
        self.area = area
        self.director = director
        self.actor = actor
        self.content = content
        self.playFrom = playFrom
        self.playURL = playURL
        self.playId = playId
        self.tag = tag
        self.action = action
        self.style = style
        self.land = land
        self.circle = circle
        self.ratio = ratio
        self.sourceKey = sourceKey
    }

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case name = "vod_name"
        case typeName = "type_name"
        case pic = "vod_pic"
        case remarks = "vod_remarks"
        case year = "vod_year"
        case area = "vod_area"
        case director = "vod_director"
        case actor = "vod_actor"
        case content = "vod_content"
        case playFrom = "vod_play_from"
        case playURL = "vod_play_url"
        case playId = "vod_play_id"
        case tag = "vod_tag"
        case action
        case style
        case land
        case circle
        case ratio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vodId = try container.flexibleString(forKey: .vodId)
        name = try container.flexibleString(forKey: .name)
        typeName = try container.flexibleStringIfPresent(forKey: .typeName)
        pic = try container.flexibleStringIfPresent(forKey: .pic)
        remarks = try container.flexibleStringIfPresent(forKey: .remarks)
        year = try container.flexibleStringIfPresent(forKey: .year)
        area = try container.flexibleStringIfPresent(forKey: .area)
        director = try container.flexibleStringIfPresent(forKey: .director)
        actor = try container.flexibleStringIfPresent(forKey: .actor)
        content = try container.flexibleStringIfPresent(forKey: .content)
        playFrom = try container.flexibleStringIfPresent(forKey: .playFrom)
        playURL = try container.flexibleStringIfPresent(forKey: .playURL)
        playId = try container.flexibleStringIfPresent(forKey: .playId)
        tag = try container.flexibleStringIfPresent(forKey: .tag)
        action = try container.flexibleStringIfPresent(forKey: .action)
        style = try container.decodeIfPresent(SiteStyle.self, forKey: .style)
        land = try container.flexibleIntIfPresent(forKey: .land)
        circle = try container.flexibleIntIfPresent(forKey: .circle)
        ratio = try container.flexibleDoubleIfPresent(forKey: .ratio)
    }
}

public struct MediaResult: Codable, Equatable, Sendable {
    public var classes: [Category]
    public var list: [MediaItem]
    public var filters: [String: [SourceFilter]]?
    public var url: JSONValue?
    public var header: [String: String]?
    public var msg: String?
    public var web: WebPlayback?
    public var danmaku: [Danmaku]?
    public var subs: [Subtitle]?
    public var skips: [SkipSegment]?
    public var playUrl: String?
    public var artwork: String?
    public var jxFrom: String?
    public var flag: String?
    public var desc: String?
    public var format: String?
    public var click: String?
    public var key: String?
    public var position: Int64?
    public var pagecount: Int64?
    public var parse: Int?
    public var code: Int?
    public var jx: Int?
    public var drm: DRM?
    public var timeshift: JSONValue?
    public var rawContent: String?

    public init(
        classes: [Category] = [],
        list: [MediaItem] = [],
        filters: [String: [SourceFilter]]? = nil,
        url: JSONValue? = nil,
        header: [String: String]? = nil,
        msg: String? = nil
    ) {
        self.classes = classes
        self.list = list
        self.filters = filters
        self.url = url
        self.header = header
        self.msg = msg
    }

    enum CodingKeys: String, CodingKey {
        case classes = "class"
        case list
        case filters
        case url
        case header
        case msg
        case web
        case danmaku
        case subs
        case skips
        case playUrl
        case artwork
        case jxFrom
        case flag
        case desc
        case format
        case click
        case key
        case position
        case pagecount
        case parse
        case code
        case jx
        case drm
        case timeshift
        case rawContent = "content"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        classes = try container.decodeIfPresent([Category].self, forKey: .classes) ?? []
        list = try container.decodeIfPresent([MediaItem].self, forKey: .list) ?? []
        filters = try container.decodeIfPresent([String: [SourceFilter]].self, forKey: .filters)
        url = try container.decodeIfPresent(JSONValue.self, forKey: .url)
        header = try container.decodeIfPresent([String: String].self, forKey: .header)
        msg = try container.decodeIfPresent(String.self, forKey: .msg)
        web = try container.decodeIfPresent(WebPlayback.self, forKey: .web)
        danmaku = try container.decodeIfPresent([Danmaku].self, forKey: .danmaku)
        subs = try container.decodeIfPresent([Subtitle].self, forKey: .subs)
        skips = try container.decodeIfPresent([SkipSegment].self, forKey: .skips)
        playUrl = try container.decodeIfPresent(String.self, forKey: .playUrl)
        artwork = try container.decodeIfPresent(String.self, forKey: .artwork)
        jxFrom = try container.decodeIfPresent(String.self, forKey: .jxFrom)
        flag = try container.decodeIfPresent(String.self, forKey: .flag)
        desc = try container.decodeIfPresent(String.self, forKey: .desc)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        click = try container.decodeIfPresent(String.self, forKey: .click)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        position = try container.flexibleInt64IfPresent(forKey: .position)
        pagecount = try container.flexibleInt64IfPresent(forKey: .pagecount)
        parse = try container.flexibleIntIfPresent(forKey: .parse)
        code = try container.flexibleIntIfPresent(forKey: .code)
        jx = try container.flexibleIntIfPresent(forKey: .jx)
        drm = try container.decodeIfPresent(DRM.self, forKey: .drm)
        timeshift = try container.decodeIfPresent(JSONValue.self, forKey: .timeshift)
        rawContent = try container.decodeIfPresent(String.self, forKey: .rawContent)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(classes, forKey: .classes)
        try container.encode(list, forKey: .list)
        try container.encodeIfPresent(filters, forKey: .filters)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(header, forKey: .header)
        try container.encodeIfPresent(msg, forKey: .msg)
        try container.encodeIfPresent(web, forKey: .web)
        try container.encodeIfPresent(danmaku, forKey: .danmaku)
        try container.encodeIfPresent(subs, forKey: .subs)
        try container.encodeIfPresent(skips, forKey: .skips)
        try container.encodeIfPresent(playUrl, forKey: .playUrl)
        try container.encodeIfPresent(artwork, forKey: .artwork)
        try container.encodeIfPresent(jxFrom, forKey: .jxFrom)
        try container.encodeIfPresent(flag, forKey: .flag)
        try container.encodeIfPresent(desc, forKey: .desc)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(click, forKey: .click)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(pagecount, forKey: .pagecount)
        try container.encodeIfPresent(parse, forKey: .parse)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(jx, forKey: .jx)
        try container.encodeIfPresent(drm, forKey: .drm)
        try container.encodeIfPresent(timeshift, forKey: .timeshift)
        try container.encodeIfPresent(rawContent, forKey: .rawContent)
    }
}

public struct SourceFilter: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var value: [FilterValue]
    public var initValue: String?

    enum CodingKeys: String, CodingKey {
        case key, name, value
        case initValue = "init"
    }
}

public struct FilterValue: Codable, Equatable, Sendable {
    public var name: String
    public var value: String

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case value = "v"
    }
}

public struct Subtitle: Codable, Equatable, Sendable {
    public var url: String
    public var name: String
    public var lang: String?
    public var format: String?
    public var flag: Int?
}

public struct Danmaku: Codable, Equatable, Sendable {
    public var name: String?
    public var url: String
}

public struct SkipSegment: Codable, Equatable, Sendable {
    public var type: String?
    public var start: Double
    public var end: Double?
}

public struct DRM: Codable, Equatable, Sendable {
    public var key: String
    public var type: String?
    public var header: JSONValue?
    public var forceKey: Bool?
}

public struct WebPlayback: Codable, Equatable, Sendable {
    public var url: String
    public var mode: Int?
    public var cookie: JSONValue?
}

public enum ProviderMethod: String, Codable, CaseIterable, Sendable {
    case homeContent
    case homeVideoContent
    case categoryContent
    case searchContent
    case detailContent
    case playerContent
    case liveContent
    case danmaku
    case action
    case proxy
}

