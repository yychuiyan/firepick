import Foundation
import FirepickCore

public enum PlaybackEngineKind: String, Codable, Sendable {
    case avPlayer
    case mpv
}

public struct PlaybackRequest: Equatable, Identifiable, Sendable {
    public var id: String {
        // Exclude startPosition — live progress bumps must not re-trigger PlayerView.task reload.
        "\(url.absoluteString)|\(formatHint ?? "")|\(subtitles.count)|\(skips.count)"
    }
    public var url: URL
    public var headers: [String: String]
    public var formatHint: String?
    public var startPosition: Double
    public var preferredEngine: PlaybackEngineKind?
    public var subtitles: [PlaybackSubtitle]
    public var danmaku: [PlaybackDanmaku]
    /// Mid-roll ad (and optional intro/outro) ranges from playerContent / cloud.
    public var skips: [SkipSegment]

    public init(
        url: URL,
        headers: [String: String] = [:],
        formatHint: String? = nil,
        startPosition: Double = 0,
        preferredEngine: PlaybackEngineKind? = nil,
        subtitles: [PlaybackSubtitle] = [],
        danmaku: [PlaybackDanmaku] = [],
        skips: [SkipSegment] = []
    ) {
        self.url = url
        self.headers = headers
        self.formatHint = formatHint
        self.startPosition = startPosition
        self.preferredEngine = preferredEngine
        self.subtitles = subtitles
        self.danmaku = danmaku
        self.skips = skips
    }
}

public struct PlaybackSubtitle: Equatable, Identifiable, Sendable {
    public var id: String { "\(url.absoluteString)|\(name)" }
    public var url: URL
    public var name: String
    public var language: String?

    public init(url: URL, name: String, language: String? = nil) {
        self.url = url
        self.name = name
        self.language = language
    }
}

public struct PlaybackDanmaku: Equatable, Identifiable, Sendable {
    public var id: String { "\(url.absoluteString)|\(name ?? "")" }
    public var url: URL
    public var name: String?

    public init(url: URL, name: String? = nil) {
        self.url = url
        self.name = name
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

public struct PlayerSelection: Equatable, Sendable {
    public var engine: PlaybackEngineKind
    public var reason: String
}

public struct PlayerSelector: Sendable {
    public static let nativeExtensions: Set<String> = [
        "m3u8", "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "caf", "aiff",
    ]

    public init() {}

    public func select(_ request: PlaybackRequest, mpvAvailable: Bool) throws -> PlayerSelection {
        if let preferred = request.preferredEngine {
            if preferred == .mpv && !mpvAvailable {
                throw FirepickError.unsupported("MPV 内核未链接")
            }
            return .init(engine: preferred, reason: "用户指定播放器")
        }

        let hint = request.formatHint
            .flatMap(URL.init(string:))
            .map(\.path)
            ?? request.url.path
        let fileExtension = URL(fileURLWithPath: hint).pathExtension.lowercased()
        if Self.nativeExtensions.contains(fileExtension) {
            return .init(engine: .avPlayer, reason: "系统原生格式")
        }
        guard mpvAvailable else {
            throw FirepickError.unsupported("该格式需要 MPV，但当前构建未链接 MPVKit")
        }
        let reason = ["iso", "mkv"].contains(fileExtension)
            ? "ISO / Matroska 容器"
            : "需要扩展格式支持"
        return .init(engine: .mpv, reason: reason)
    }
}

