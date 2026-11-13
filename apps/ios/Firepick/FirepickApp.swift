import SwiftUI
import UIKit

@MainActor
final class OrientationBridge {
  static let shared = OrientationBridge()
  private let stateLock = NSLock()
  private var storedMask: UIInterfaceOrientationMask = .allButUpsideDown

  var mask: UIInterfaceOrientationMask {
    stateLock.lock()
    defer { stateLock.unlock() }
    return storedMask
  }

  func setMask(_ mask: UIInterfaceOrientationMask) {
    stateLock.lock()
    storedMask = mask
    stateLock.unlock()
  }

  static func lockCurrent() {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first
    let mask: UIInterfaceOrientationMask
    switch scene?.interfaceOrientation {
    case .landscapeLeft:
      mask = .landscapeLeft
    case .landscapeRight:
      mask = .landscapeRight
    case .portraitUpsideDown:
      mask = .portraitUpsideDown
    default:
      mask = .portrait
    }
    shared.setMask(mask)
    apply()
  }

  static func lock(_ mask: UIInterfaceOrientationMask) {
    shared.setMask(mask)
    apply()
  }

  /// Prefer landscape for fullscreen. Force one side first so iOS actually rotates.
  static func enterLandscape() {
    shared.setMask(.landscapeRight)
    apply(force: .landscapeRight)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
      guard shared.mask == .landscapeRight || shared.mask == .landscape else { return }
      shared.setMask(.landscape)
      apply()
    }
  }

  /// Force portrait when leaving fullscreen, then restore free rotation.
  static func enterPortraitThenUnlock() {
    shared.setMask(.portrait)
    apply(force: .portrait)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
      unlock()
    }
  }

  static func unlock() {
    shared.setMask(.allButUpsideDown)
    apply()
  }

  private static func apply(force: UIInterfaceOrientation? = nil) {
    let mask = shared.mask
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
      for window in scene.windows {
        pokeOrientation(window.rootViewController)
      }
    }
    // Last resort on device. Skip on Simulator — the nudge rotates the layer
    // without swapping bounds and leaves a sideways letterbox.
    #if !targetEnvironment(simulator)
      if let force {
        let value: Int
        switch force {
        case .landscapeRight: value = UIInterfaceOrientation.landscapeRight.rawValue
        case .landscapeLeft: value = UIInterfaceOrientation.landscapeLeft.rawValue
        case .portraitUpsideDown: value = UIInterfaceOrientation.portraitUpsideDown.rawValue
        default: value = UIInterfaceOrientation.portrait.rawValue
        }
        UIDevice.current.setValue(value, forKey: "orientation")
        for scene in scenes {
          for window in scene.windows {
            pokeOrientation(window.rootViewController)
          }
        }
      }
    #endif
  }

  private static func pokeOrientation(_ controller: UIViewController?) {
    guard let controller else { return }
    controller.setNeedsUpdateOfSupportedInterfaceOrientations()
    controller.children.forEach(pokeOrientation)
    if let presented = controller.presentedViewController {
      pokeOrientation(presented)
    }
  }
}

private final class FirepickAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    OrientationBridge.shared.mask
  }
}

@main
struct FirepickApp: App {
    @UIApplicationDelegateAdaptor(FirepickAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    await model.bootstrap()
                }
        }
    }
}

