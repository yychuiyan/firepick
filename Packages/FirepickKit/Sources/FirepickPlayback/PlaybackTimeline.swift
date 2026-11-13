import Foundation

/// Normalizes media timeline values before they reach SwiftUI controls.
public enum PlaybackTimeline {
  public static func duration(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 0 }
    return value
  }

  public static func position(_ value: Double, duration: Double) -> Double {
    guard value.isFinite else { return 0 }
    let safeDuration = self.duration(duration)
    guard safeDuration > 0 else { return 0 }
    return min(max(0, value), safeDuration)
  }

  public static func progressRange(duration: Double) -> ClosedRange<Double> {
    let safeDuration = self.duration(duration)
    return 0...(safeDuration > 0 ? safeDuration : 0.1)
  }
}
