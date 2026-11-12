import Foundation

public enum LiveParser {
    public static func groups(from value: JSONValue?) -> [LiveGroup] {
        guard let value else { return [] }
        if case let .array(items) = value {
            return items.compactMap(group(from:))
        }
        if case let .string(url) = value, !url.isEmpty {
            return []
        }
        return []
    }

    public static func group(from value: JSONValue) -> LiveGroup? {
        guard case let .object(object) = value,
              let name = object["name"]?.stringValue else { return nil }
        let channels = object["channel"]?.arrayValue?.compactMap(channel(from:)) ?? []
        return LiveGroup(
            name: name,
            password: object["pass"]?.stringValue,
            epg: object["epg"]?.stringValue,
            channels: channels
        )
    }

    public static func channel(from value: JSONValue) -> LiveChannel? {
        guard case let .object(object) = value,
              let name = object["name"]?.stringValue else { return nil }
        var urls: [String] = []
        if let url = object["url"]?.stringValue { urls.append(url) }
        if let values = object["urls"]?.arrayValue {
            urls.append(contentsOf: values.compactMap(\.stringValue))
        }
        guard !urls.isEmpty else { return nil }
        var headers: [String: String] = [:]
        if case let .object(values)? = object["header"] {
            for (key, item) in values where item.stringValue != nil {
                headers[key] = item.stringValue
            }
        }
        return LiveChannel(
            name: name,
            number: object["number"]?.stringValue,
            logo: object["logo"]?.stringValue,
            epg: object["epg"]?.stringValue,
            tvgId: object["tvgId"]?.stringValue,
            urls: urls,
            headers: headers
        )
    }

    public static func groups(m3u text: String) -> [LiveGroup] {
        var groups: [String: [LiveChannel]] = [:]
        var groupOrder: [String] = []
        var pending: [String: String] = [:]
        var pendingHeaders: [String: String] = [:]
        var pendingGroup: String?
        var playlistEPG: String?
        var number = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTM3U") {
                playlistEPG = attribute("url-tvg", in: line)
                    ?? attribute("x-tvg-url", in: line)
                    ?? attribute("tvg-url", in: line)
            } else if line.hasPrefix("#EXTINF:") {
                pending["name"] = value(afterComma: line) ?? "未命名频道"
                pendingGroup = attribute("group-title", in: line)
                pending["tvg-id"] = attribute("tvg-id", in: line)
                pending["tvg-logo"] = attribute("tvg-logo", in: line)
                pending["tvg-chno"] = attribute("tvg-chno", in: line)
                if let agent = attribute("http-user-agent", in: line) {
                    pendingHeaders["User-Agent"] = agent
                }
                if let referrer = attribute("http-referrer", in: line) {
                    pendingHeaders["Referer"] = referrer
                }
            } else if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count))
            } else if line.hasPrefix("#EXTHTTP:") {
                let value = String(line.dropFirst("#EXTHTTP:".count))
                pendingHeaders.merge(parsedHeaderObject(value)) { _, new in new }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = String(line.dropFirst("#EXTVLCOPT:".count))
                if option.hasPrefix("http-user-agent=") {
                    pendingHeaders["User-Agent"] = String(option.dropFirst("http-user-agent=".count))
                } else if option.hasPrefix("http-referrer=") {
                    pendingHeaders["Referer"] = String(option.dropFirst("http-referrer=".count))
                } else if option.hasPrefix("http-referer=") {
                    pendingHeaders["Referer"] = String(option.dropFirst("http-referer=".count))
                } else if option.hasPrefix("http-origin=") {
                    pendingHeaders["Origin"] = String(option.dropFirst("http-origin=".count))
                }
            } else if !line.hasPrefix("#") {
                let groupName = pendingGroup ?? "其他"
                if groups[groupName] == nil {
                    groups[groupName] = []
                    groupOrder.append(groupName)
                }
                let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                let url = parts[0]
                var headers = pendingHeaders
                if parts.count > 1 {
                    headers.merge(parsedHeaderObject(parts[1])) { _, new in new }
                }
                let name = pending["name"] ?? "未命名频道"
                if let existing = groups[groupName]?.firstIndex(where: { $0.name == name }) {
                    if !groups[groupName]![existing].urls.contains(url) {
                        groups[groupName]![existing].urls.append(url)
                    }
                    groups[groupName]![existing].headers.merge(headers) { old, _ in old }
                } else {
                    number += 1
                    groups[groupName]?.append(
                        LiveChannel(
                            name: name,
                            number: pending["tvg-chno"] ?? String(number),
                            logo: pending["tvg-logo"],
                            epg: playlistEPG,
                            tvgId: pending["tvg-id"],
                            urls: [url],
                            headers: headers
                        )
                    )
                }
                pending.removeAll()
                pendingHeaders.removeAll()
                pendingGroup = nil
            }
        }

        return groupOrder.map {
            LiveGroup(
                name: $0,
                epg: playlistEPG,
                channels: groups[$0] ?? []
            )
        }
    }

    private static func parsedHeaderObject(_ value: String) -> [String: String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object.reduce(into: [:]) { output, entry in
                if let value = entry.value as? String {
                    output[normalizedHeaderName(entry.key)] = value
                }
            }
        }
        var output: [String: String] = [:]
        let separators = CharacterSet(charactersIn: "&|")
        for item in trimmed.components(separatedBy: separators) {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            output[normalizedHeaderName(pair[0])] = pair[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return output
    }

    private static func normalizedHeaderName(_ value: String) -> String {
        switch value.lowercased() {
        case "ua", "user-agent": "User-Agent"
        case "referer", "referrer": "Referer"
        case "origin": "Origin"
        case "cookie": "Cookie"
        default: value
        }
    }

    public static func groups(txt text: String) -> [LiveGroup] {
        var groups: [String: [LiveChannel]] = [:]
        var order: [String] = []
        var current = "其他"
        var headers: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasSuffix(",#genre#") {
                current = String(line.dropLast(",#genre#".count))
                if groups[current] == nil {
                    groups[current] = []
                    order.append(current)
                }
                continue
            }
            if let equals = line.firstIndex(of: "="), !line[..<equals].contains(",") {
                let key = String(line[..<equals])
                let value = String(line[line.index(after: equals)...])
                if key.caseInsensitiveCompare("ua") == .orderedSame { headers["User-Agent"] = value }
                if key.caseInsensitiveCompare("referer") == .orderedSame { headers["Referer"] = value }
                continue
            }
            let parts = line.split(separator: ",", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let urls = parts[1].split(separator: "#").map {
                String($0).split(separator: "$", maxSplits: 1).first.map(String.init) ?? String($0)
            }
            let name = parts[0]
            if groups[current] == nil {
                groups[current] = []
                order.append(current)
            }
            groups[current]?.append(LiveChannel(name: name, urls: urls, headers: headers))
        }
        return order.map { LiveGroup(name: $0, channels: groups[$0] ?? []) }
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        let pattern = #"\b\#(name)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func value(afterComma line: String) -> String? {
        guard let comma = line.lastIndex(of: ",") else { return nil }
        let value = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

