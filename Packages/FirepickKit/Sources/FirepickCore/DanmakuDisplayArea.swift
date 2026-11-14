import Foundation

/// How much of the player height scrolling danmaku may occupy (B站-style).
public enum DanmakuDisplayArea: String, CaseIterable, Codable, Sendable, Identifiable {
  case full
  case threeQuarters
  case half
  case quarter
  case oneLine

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .full: "满屏"
    case .threeQuarters: "3/4屏"
    case .half: "半屏"
    case .quarter: "1/4屏"
    case .oneLine: "一行"
    }
  }

  /// Fraction of the player height used for scrolling lanes (oneLine → single lane).
  public var heightFraction: Double {
    switch self {
    case .full: 1
    case .threeQuarters: 0.75
    case .half: 0.5
    case .quarter: 0.25
    case .oneLine: 0
    }
  }
}
