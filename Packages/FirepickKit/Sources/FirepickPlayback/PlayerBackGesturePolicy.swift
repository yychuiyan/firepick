import CoreGraphics

public enum PlayerBackGesturePolicy {
  public static func isLeftEdgeStart(
    _ startX: CGFloat,
    stageWidth: CGFloat
  ) -> Bool {
    let edgeWidth = min(72, max(44, stageWidth * 0.16))
    return startX >= 0 && startX <= edgeWidth
  }

  public static func isBackGestureStart(
    _ startX: CGFloat,
    stageWidth: CGFloat,
    allowsRightHalfStart: Bool = false
  ) -> Bool {
    if isLeftEdgeStart(startX, stageWidth: stageWidth) {
      return true
    }
    return allowsRightHalfStart
      && startX >= stageWidth * 0.5
      && startX <= stageWidth
  }

  public static func shouldNavigateBack(
    startLocation: CGPoint,
    translation: CGSize,
    stageWidth: CGFloat,
    allowsRightHalfStart: Bool = false
  ) -> Bool {
    let minimumDistance = min(56, max(44, stageWidth * 0.12))
    guard isBackGestureStart(
      startLocation.x,
      stageWidth: stageWidth,
      allowsRightHalfStart: allowsRightHalfStart
    ) else { return false }
    guard translation.width >= minimumDistance else { return false }
    return abs(translation.width) > abs(translation.height) * 1.35
  }
}
