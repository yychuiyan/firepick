import UIKit

/// After Detail/player hides the tab bar (esp. across landscape), iOS liquid-glass
/// sometimes comes back without its material — content shows straight through.
enum TabBarChrome {
  @MainActor
  static func restore() {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    UITabBar.appearance().standardAppearance = appearance
    UITabBar.appearance().scrollEdgeAppearance = appearance

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows {
        apply(appearance, in: window)
      }
    }
  }

  @MainActor
  private static func apply(_ appearance: UITabBarAppearance, in root: UIView) {
    var stack: [UIView] = [root]
    while let view = stack.popLast() {
      if let tabBar = view as? UITabBar {
        tabBar.isHidden = false
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.setNeedsLayout()
        tabBar.layoutIfNeeded()
      }
      stack.append(contentsOf: view.subviews)
    }
  }
}
