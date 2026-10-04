import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var privacyEnabled = false
  private var privacyCover: UIView?

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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
