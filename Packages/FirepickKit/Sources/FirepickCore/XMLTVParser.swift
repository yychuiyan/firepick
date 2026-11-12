import Foundation

public enum XMLTVParser {
    public static func programs(_ data: Data) -> [LiveProgram] {
        let delegate = ProgramBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.finish()
    }
}

private final class ProgramBuilder: NSObject, XMLParserDelegate {
    private struct Entry {
        var channelId: String
        var title: String
        var description: String?
        var start: Date
        var stop: Date?
    }

    private var entries: [Entry] = []
    private var channelId: String?
    private var start: Date?
    private var stop: Date?
    private var title = ""
    private var summary = ""
    private var textElement: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "programme":
            channelId = attributeDict["channel"]
            start = parseDate(attributeDict["start"])
            stop = parseDate(attributeDict["stop"])
            title = ""
            summary = ""
        case "title", "desc":
            textElement = elementName.lowercased()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let textElement else { return }
        if textElement == "title" {
            title += string
        } else {
            summary += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "title" || name == "desc" {
            textElement = nil
        }
        guard name == "programme",
              let channelId,
              let start,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        entries.append(
            Entry(
                channelId: channelId,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                start: start,
                stop: stop
            )
        )
    }

    func finish() -> [LiveProgram] {
        let sorted = entries.sorted {
            $0.channelId == $1.channelId
                ? $0.start < $1.start
                : $0.channelId < $1.channelId
        }
        var output: [LiveProgram] = []
        for index in sorted.indices {
            var stop = sorted[index].stop
            if stop == nil {
                let next = sorted[(index + 1)...].first {
                    $0.channelId == sorted[index].channelId
                }
                stop = next?.start
            }
            guard let stop, stop > sorted[index].start else { continue }
            output.append(
                LiveProgram(
                    channelId: sorted[index].channelId,
                    title: sorted[index].title,
                    description: sorted[index].description,
                    start: sorted[index].start,
                    stop: stop
                )
            )
        }
        return output.sorted {
            $0.channelId == $1.channelId
                ? $0.start < $1.start
                : $0.channelId < $1.channelId
        }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard var value, value.count >= 14 else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateText = String(value.prefix(14))
        let suffix = String(value.dropFirst(14)).trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        if let offset = parseOffset(suffix) {
            formatter.timeZone = TimeZone(secondsFromGMT: offset)
        }
        return formatter.date(from: dateText)
    }

    private func parseOffset(_ value: String) -> Int? {
        guard value.count >= 5 else { return nil }
        let sign: Int
        switch value.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let digits = value.dropFirst().prefix(4)
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 23, minutes <= 59 else {
            return nil
        }
        return sign * (hours * 3_600 + minutes * 60)
    }
}
