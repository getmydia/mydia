import Flutter
import UIKit

/// Owns the window. Apps built against the iOS 27 SDK must adopt the scene
/// lifecycle or UIKit traps at launch, so everything that touches the window
/// lives here rather than in `AppDelegate`.
class SceneDelegate: FlutterSceneDelegate {
  private var privacyCover: UIView?

  private var appDelegate: AppDelegate? {
    UIApplication.shared.delegate as? AppDelegate
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    installNativeTabBar()
  }

  /// On iOS 26 iPhones, puts a native tab bar over the Flutter view; on
  /// iOS 26 iPads, a native sidebar. Everywhere else the root stays the
  /// `FlutterViewController` and the plugin answers `mode` with "none".
  private func installNativeTabBar() {
    #if compiler(>=6.2)
    guard #available(iOS 26.0, *),
          [.phone, .pad].contains(UIDevice.current.userInterfaceIdiom) else { return }
    guard let plugin = appDelegate?.nativeTabBarPlugin else {
      NSLog("[NativeTabBar] root swap skipped: plugin not registered")
      return
    }
    guard let window, let flutter = window.rootViewController as? FlutterViewController else {
      NSLog("[NativeTabBar] root swap skipped: window or FlutterViewController root missing")
      return
    }
    let root = MydiaRootViewController(flutterViewController: flutter)
    plugin.attach(root.tabs)
    window.rootViewController = root
    #endif
  }

  // The app switcher snapshots the window after this returns.
  override func sceneWillResignActive(_ scene: UIScene) {
    super.sceneWillResignActive(scene)
    guard appDelegate?.privacyEnabled == true, privacyCover == nil, let window else { return }
    let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    cover.frame = window.bounds
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(cover)
    privacyCover = cover
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }
}
