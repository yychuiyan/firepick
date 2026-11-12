import Foundation

public enum ConfigurationDetector {
    public static func detect(_ data: Data) throws -> DetectedConfiguration {
        let data = try ConfigurationDecoder.normalize(data)
        let jsonObject = try? JSONSerialization.jsonObject(with: data)

        if let object = jsonObject as? [String: Any] {
            if object["urls"] != nil {
                let depot = try JSONDecoder().decode(ConfigurationDepotDocument.self, from: data)
                guard !depot.urls.isEmpty else {
                    throw FirepickError.invalidConfiguration("配置仓库 urls 为空")
                }
                return .depot(depot)
            }
            if object["sites"] != nil {
                return .vod(try JSONDecoder().decode(VodConfiguration.self, from: data))
            }
            if let lives = object["lives"] as? [[String: Any]], !lives.isEmpty {
                let document = try JSONDecoder().decode(LiveConfigurationDocument.self, from: data)
                return .live(
                    name: document.lives.first?.name ?? "直播源",
                    groups: document.lives.flatMap { LiveParser.groups(from: $0.groups) }
                )
            }
        }

        if let groups = try? JSONDecoder().decode([LiveGroup].self, from: data), !groups.isEmpty {
            return .live(name: "直播源", groups: groups)
        }
        if jsonObject is [Any] {
            throw FirepickError.invalidConfiguration(
                "JSON 顶层是数组但不是直播源。点播配置需要使用包含 sites 的对象格式"
            )
        }

        let text = String(decoding: data, as: UTF8.self)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedText.hasPrefix("<!doctype html")
            || normalizedText.hasPrefix("<html")
            || normalizedText.contains("<html") {
            throw FirepickError.invalidConfiguration(
                "加载到的是网页而不是配置。请使用 Raw、原始 JSON 或直链地址"
            )
        }
        if text.range(of: #"^\s*#EXTM3U"#, options: .regularExpression) != nil {
            return .live(name: "M3U 直播源", groups: LiveParser.groups(m3u: text))
        }
        if text.contains("#genre#") {
            return .live(name: "TXT 直播源", groups: LiveParser.groups(txt: text))
        }

        if let object = jsonObject as? [String: Any],
           object["sites"] == nil,
           object["lives"] == nil,
           object["urls"] == nil {
            throw FirepickError.invalidConfiguration(
                "JSON 中没有 sites、lives 或 urls。当前地址可能是单个接口，请使用完整的 TVBox/CatVod 配置"
            )
        }

        throw FirepickError.invalidConfiguration("无法识别为点播配置、多仓、直播 JSON、M3U 或 TXT")
    }
}

