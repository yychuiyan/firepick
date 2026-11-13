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

  static func unlock() {
    shared.setMask(.allButUpsideDown)
    apply()
  }

  private static func apply() {
    let mask = shared.mask
    guard let scene = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .first
    else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
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

