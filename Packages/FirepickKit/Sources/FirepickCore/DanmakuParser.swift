import Foundation

public enum DanmakuMode: String, Codable, Sendable {
    case scrolling
    case top
    case bottom
    case reverse
}

public struct DanmakuComment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var time: Double
    public var text: String
    public var mode: DanmakuMode
    public var color: String
    public var fontSize: Double

    public init(
        id: String,
        time: Double,
        text: String,
        mode: DanmakuMode = .scrolling,
        color: String = "#FFFFFF",
        fontSize: Double = 24
    ) {
        self.id = id
        self.time = max(0, time)
        self.text = text
        self.mode = mode
        self.color = color
        self.fontSize = max(12, min(fontSize, 64))
    }
}

public enum DanmakuParser {
    public static func parse(_ data: Data) -> [DanmakuComment] {
        let json = try? JSONSerialization.jsonObject(with: data)
        if let json {
            var comments: [DanmakuComment] = []
            collectJSON(json, into: &comments)
            if !comments.isEmpty {
                return normalize(comments)
            }
        }

        let delegate = XMLDanmakuDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        if parser.parse(), !delegate.comments.isEmpty {
            return normalize(delegate.comments)
        }
        return normalize(parsePlainText(String(decoding: data, as: UTF8.self)))
    }

    private static func collectJSON(_ value: Any, into comments: inout [DanmakuComment]) {
        if let array = value as? [Any] {
            for item in array {
                collectJSON(item, into: &comments)
            }
            return
        }
        guard let object = value as? [String: Any] else { return }
        // 弹弹play: { "p": "12.5,1,16777215", "m": "text" }
        if let p = string(object["p"]),
          let text = string(object["m"])
            ?? string(object["text"])
            ?? string(object["content"])
            ?? string(object["msg"])
        {
            if let comment = parseParameterized(time: p, text: text, identifier: comments.count) {
                comments.append(comment)
                return
            }
        }
        if let text = string(object["text"])
            ?? string(object["content"])
            ?? string(object["msg"])
            ?? string(object["m"]) {
            let time = parsedTime(object)
            let mode = parseMode(object["mode"] ?? object["type"])
            let color = parseColor(object["color"] ?? object["colour"])
            let size = number(object["fontSize"] ?? object["size"] ?? object["fontsize"]) ?? 24
            guard time.isFinite, time >= 0 else { return }
            comments.append(
                DanmakuComment(
                    id: string(object["id"]) ?? "\(time)|\(text)|\(comments.count)",
                    time: time,
                    text: text,
                    mode: mode,
                    color: color,
                    fontSize: size
                )
            )
            return
        }
        for key in ["data", "comments", "danmaku", "list", "elems", "items"] {
            if let nested = object[key] {
                collectJSON(nested, into: &comments)
            }
        }
    }

    fileprivate static func parseParameterized(
        time rawTime: String?,
        text: String,
        identifier: Int
    ) -> DanmakuComment? {
        guard let rawTime else { return nil }
        let fields = rawTime.split(separator: ",", omittingEmptySubsequences: false)
        guard let first = fields.first.flatMap({ Double($0) }) else { return nil }
        let isMilliseconds = first > 10_000 || fields.count > 3 && first > 1_000
        let time = isMilliseconds ? first / 1_000 : first
        let mode = fields.count > 1 ? parseMode(String(fields[1])) : .scrolling
        // B站 XML: time,mode,size,color,…  弹弹 JSON: time,mode,color
        let size: Double
        let color: String
        if fields.count >= 4 {
            size = Double(fields[2]) ?? 24
            color = parseColor(String(fields[3]))
        } else if fields.count == 3 {
            size = 24
            color = parseColor(String(fields[2]))
        } else {
            size = 24
            color = "#FFFFFF"
        }
        return DanmakuComment(
            id: "xml|\(identifier)|\(time)|\(text)",
            time: time,
            text: text,
            mode: mode,
            color: color,
            fontSize: size
        )
    }

    private static func parsePlainText(_ text: String) -> [DanmakuComment] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let open = trimmed.firstIndex(of: "["),
                  let close = trimmed.firstIndex(of: "]"),
                  open < close else {
                return nil
            }
            let timeText = trimmed[trimmed.index(after: open)..<close]
            guard let time = Double(timeText) else { return nil }
            let content = trimmed[trimmed.index(after: close)...]
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return DanmakuComment(
                id: "text|\(index)",
                time: time,
                text: content
            )
        }
    }

    private static func normalize(_ items: [DanmakuComment]) -> [DanmakuComment] {
        var seen = Set<String>()
        return items
            .filter {
                $0.time.isFinite
                    && $0.time >= 0
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && seen.insert("\(Int64($0.time * 1_000))|\($0.text)").inserted
            }
            .sorted {
                $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
            }
    }

    private static func parseMode(_ value: Any?) -> DanmakuMode {
        let numeric = number(value)
        switch numeric {
        case 4:
            return .bottom
        case 5:
            return .top
        case 6:
            return .reverse
        default: break
        }
        switch string(value)?.lowercased() {
        case "top", "固定顶部", "5":
            return .top
        case "bottom", "固定底部", "4":
            return .bottom
        case "reverse", "逆向", "6":
            return .reverse
        default:
            return .scrolling
        }
    }

    private static func parsedTime(_ object: [String: Any]) -> Double {
        if let time = number(object["time"]) {
            return time
        }
        if let timeMs = number(object["timeMs"]) {
            return timeMs / 1_000
        }
        if let time = number(object["t"]) {
            return time
        }
        if let progress = number(object["progress"]) {
            return progress / 1_000
        }
        if let start = number(object["start"]) {
            return start > 10_000 ? start / 1_000 : start
        }
        return 0
    }

    private static func parseColor(_ value: Any?) -> String {
        if let number = number(value) {
            let rgb = max(0, min(0xFF_FF_FF, Int(number)))
            return String(format: "#%06X", rgb)
        }
        guard var text = string(value)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else {
            return "#FFFFFF"
        }
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        if text.lowercased().hasPrefix("0x") {
            text.removeFirst(2)
        }
        if let number = UInt32(text, radix: 16) {
            return String(format: "#%06X", number & 0xFF_FF_FF)
        }
        return "#FFFFFF"
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

private final class XMLDanmakuDelegate: NSObject, XMLParserDelegate {
    var comments: [DanmakuComment] = []
    private var text = ""
    private var parameter: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard ["d", "danmaku", "comment", "item"].contains(elementName.lowercased()) else {
            return
        }
        parameter = attributeDict["p"]
            ?? attributeDict["time"]
            ?? attributeDict["progress"]
        text = ""
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
        guard let parameter,
              let comment = DanmakuParser.parseParameterized(
                time: parameter,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                identifier: comments.count
              ) else {
            self.parameter = nil
            text = ""
            return
        }
        comments.append(comment)
        self.parameter = nil
        text = ""
    }
}
