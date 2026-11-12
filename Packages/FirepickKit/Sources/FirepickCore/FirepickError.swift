import Foundation

public enum FirepickError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case sourceUnavailable(String)
    case bridgeUnavailable
    case bridgeUnauthorized
    case bridgeProtocol(String)
    case network(String)
    case provider(String)
    case playback(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            "配置无效：\(message)"
        case let .sourceUnavailable(message):
            "数据源不可用：\(message)"
        case .bridgeUnavailable:
            "Android Bridge 当前不可达"
        case .bridgeUnauthorized:
            "Android Bridge 尚未配对或授权已失效"
        case let .bridgeProtocol(message):
            "Bridge 协议错误：\(message)"
        case let .network(message):
            "网络错误：\(message)"
        case let .provider(message):
            "数据源错误：\(message)"
        case let .playback(message):
            "播放错误：\(message)"
        case let .unsupported(message):
            "当前平台不支持：\(message)"
        }
    }
}

