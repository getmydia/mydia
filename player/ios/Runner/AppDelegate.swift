import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var privacyEnabled = false
  private var privacyCover: UIView?

  /// Owns `mydia/native-tab-bar`. Kept alive for the app's lifetime.
  private var nativeTabBarPlugin: NativeTabBarPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Configure audio session for AirPlay
    configureAudioSession()

    // Register AirPlay platform channel
    if let controller = window?.rootViewController as? FlutterViewController {
      AirPlayChannelHandler.register(with: registrar(forPlugin: "AirPlayChannelHandler")!)
    }

    // Window privacy: blur the app switcher snapshot while a locked or
    // hidden server is open.
    if let privacyRegistrar = registrar(forPlugin: "WindowPrivacy") {
      FlutterMethodChannel(name: "dev.mydia.player/privacy",
                           binaryMessenger: privacyRegistrar.messenger())
        .setMethodCallHandler { [weak self] call, result in
          guard call.method == "setSecure",
                let args = call.arguments as? [String: Any] else {
            result(FlutterMethodNotImplemented)
            return
          }
          self?.privacyEnabled = (args["secure"] as? Bool) ?? false
          result(nil)
        }
    }

    // Must stay the last step before `super`: `FlutterAppDelegate` finds each
    // plugin registrar through `window.rootViewController as? FlutterViewController`,
    // which stops matching once the tab bar controller becomes the root.
    installNativeTabBar()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// On iOS 26 iPhones, puts a native tab bar over the Flutter view.
  /// Everywhere else the root stays the `FlutterViewController` and the
  /// plugin only answers `isSupported` with false.
  private func installNativeTabBar() {
    guard let registrar = registrar(forPlugin: "NativeTabBarPlugin") else { return }
    let plugin = NativeTabBarPlugin(messenger: registrar.messenger())
    nativeTabBarPlugin = plugin

    #if compiler(>=6.2)
    guard #available(iOS 26.0, *),
          UIDevice.current.userInterfaceIdiom == .phone else { return }
    guard let window, let flutter = window.rootViewController as? FlutterViewController else {
      NSLog("[NativeTabBar] root swap skipped: window or FlutterViewController root missing")
      return
    }
    let tabs = MydiaTabBarController(flutterViewController: flutter)
    plugin.attach(tabs)
    window.rootViewController = tabs
    #endif
  }

  // The app switcher snapshots the window after this returns.
  override func applicationWillResignActive(_ application: UIApplication) {
    super.applicationWillResignActive(application)
    guard privacyEnabled, privacyCover == nil, let window = window else { return }
    let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    cover.frame = window.bounds
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(cover)
    privacyCover = cover
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }

  private func configureAudioSession() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // Set category to playback to enable AirPlay
      try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetooth])
      try audioSession.setActive(true)
    } catch {
      print("Failed to configure audio session for AirPlay: \(error)")
    }
  }
}
