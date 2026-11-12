import Foundation
import FirepickCore

enum XMLMediaDecoder {
    static func decode(_ data: Data) throws -> MediaResult {
        let delegate = XMLNodeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw FirepickError.provider(parser.parserError?.localizedDescription ?? "XML 解析失败")
        }

        let root = delegate.root
        let categories = root.descendants(named: "ty").compactMap { node -> FirepickCore.Category? in
            let id = node.attribute("id") ?? node.attribute("type_id") ?? node.text.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { return nil }
            return FirepickCore.Category(
                typeId: id,
                typeName: node.text.trimmingCharacters(in: .whitespaces),
                typeFlag: node.attribute("flag"),
                filters: nil
            )
        }

        let videos = root.descendants(named: "video").map { node in
            func value(_ names: String...) -> String? {
                for name in names {
                    if let text = node.descendants(named: name).first?.text.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                        return text
                    }
                }
                return nil
            }

            return MediaItem(
                vodId: value("id", "vod_id") ?? "",
                name: value("name", "vod_name") ?? "未命名",
                typeName: value("type", "type_name"),
                pic: value("pic", "vod_pic"),
                remarks: value("note", "vod_remarks"),
                year: value("year", "vod_year"),
                area: value("area", "vod_area"),
                director: value("director", "vod_director"),
                actor: value("actor", "vod_actor"),
                content: value("des", "vod_content"),
                playFrom: value("dt", "vod_play_from"),
                playURL: value("dd", "vod_play_url"),
                playId: value("vod_play_id"),
                tag: value("vod_tag"),
                action: value("action"),
                style: nil,
                land: nil,
                circle: nil,
                ratio: nil
            )
        }.filter { !$0.vodId.isEmpty }

        return MediaResult(classes: categories, list: videos)
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func attribute(_ key: String) -> String? {
        attributes[key]
    }

    func descendants(named target: String) -> [XMLNode] {
        children.flatMap { child in
            (child.name == target ? [child] : []) + child.descendants(named: target)
        }
    }
}

private final class XMLNodeBuilder: NSObject, XMLParserDelegate {
    let root = XMLNode(name: "root", attributes: [:])
    private var stack: [XMLNode] = []

    override init() {
        super.init()
        stack = [root]
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLNode(name: elementName.lowercased(), attributes: attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }
}

