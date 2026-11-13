import SwiftUI

struct SubtitleCue: Identifiable, Equatable {
  var id: Int
  var start: Double
  var end: Double
  var text: String
}

enum SubtitleParser {
  static func parse(_ data: Data) -> [SubtitleCue] {
    let text = String(decoding: data, as: UTF8.self)
    if text.contains("WEBVTT") {
      return parseVTT(text)
    }
    return parseSRT(text)
  }

  private static func parseSRT(_ text: String) -> [SubtitleCue] {
    let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n\n")
    var cues: [SubtitleCue] = []
    for block in blocks {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      guard lines.count >= 2 else { continue }
      let timingIndex = lines[0].contains("-->") ? 0 : 1
      guard lines.indices.contains(timingIndex),
        lines[timingIndex].contains("-->")
      else { continue }
      let parts = lines[timingIndex].components(separatedBy: "-->")
      guard parts.count == 2,
        let start = parseTimestamp(parts[0]),
        let end = parseTimestamp(parts[1])
      else { continue }
      let body = lines[(timingIndex + 1)...]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      cues.append(
        SubtitleCue(id: cues.count, start: start, end: end, text: stripTags(body))
      )
    }
    return cues
  }

  private static func parseVTT(_ text: String) -> [SubtitleCue] {
    let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
      .components(separatedBy: "\n\n")
    var cues: [SubtitleCue] = []
    for block in blocks {
      let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("NOTE") && !$0.hasPrefix("STYLE") }
      guard let timing = lines.first(where: { $0.contains("-->") }) else { continue }
      let parts = timing.components(separatedBy: "-->")
      guard parts.count >= 2,
        let start = parseTimestamp(parts[0]),
        let end = parseTimestamp(parts[1].split(separator: " ").first.map(String.init) ?? parts[1])
      else { continue }
      let body = lines.drop(while: { !$0.contains("-->") }).dropFirst()
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { continue }
      cues.append(
        SubtitleCue(id: cues.count, start: start, end: end, text: stripTags(body))
      )
    }
    return cues
  }

  private static func parseTimestamp(_ raw: String) -> Double? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: ",", with: ".")
    let parts = value.split(separator: ":").map(String.init)
    guard parts.count == 2 || parts.count == 3 else { return nil }
    if parts.count == 2,
      let m = Double(parts[0]),
      let s = Double(parts[1])
    {
      return m * 60 + s
    }
    if parts.count == 3,
      let h = Double(parts[0]),
      let m = Double(parts[1]),
      let s = Double(parts[2])
    {
      return h * 3600 + m * 60 + s
    }
    return nil
  }

  private static func stripTags(_ text: String) -> String {
    text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
  }
}

struct SubtitleOverlay: View {
  let cues: [SubtitleCue]
  let currentTime: Double
  var fontSize: CGFloat = 18
  var color: Color = .white
  var outlined: Bool = true

  private var activeText: String? {
    cues.first(where: { currentTime >= $0.start && currentTime < $0.end })?.text
  }

  var body: some View {
    if let activeText {
      Text(activeText)
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(color)
        .multilineTextAlignment(.center)
        .shadow(color: outlined ? .black.opacity(0.9) : .clear, radius: outlined ? 1.2 : 0)
        .padding(.horizontal, 16)
        .padding(.bottom, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
  }
}
