import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Read by `SceneDelegate` when the scene resigns active.
  private(set) var privacyEnabled = false

  /// Owns `mydia/native-tab-bar`. Kept alive for the app's lifetime;
  /// `SceneDelegate` attaches it to the tab bar controller.
  private(set) var nativeTabBarPlugin: NativeTabBarPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure audio session for AirPlay
    configureAudioSession()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Runs when the storyboard's FlutterViewController creates its engine,
  // before the scene connects. Registering through the engine's own registry
  // keeps working after `SceneDelegate` replaces the window root.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    let registry = engineBridge.pluginRegistry
    GeneratedPluginRegistrant.register(with: registry)

    // Register AirPlay platform channel
    if let airPlayRegistrar = registry.registrar(forPlugin: "AirPlayChannelHandler") {
      AirPlayChannelHandler.register(with: airPlayRegistrar)
    }

    // Window privacy: blur the app switcher snapshot while a locked or
    // hidden server is open.
    if let privacyRegistrar = registry.registrar(forPlugin: "WindowPrivacy") {
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

    if let tabBarRegistrar = registry.registrar(forPlugin: "NativeTabBarPlugin") {
      nativeTabBarPlugin = NativeTabBarPlugin(messenger: tabBarRegistrar.messenger())
    }
  }

  private func configureAudioSession() {
    do {
      let audioSession = AVAudioSession.sharedInstance()
      // Playback already routes to AirPlay and Bluetooth A2DP. The
      // .allowAirPlay and .allowBluetooth(HFP) options are only valid with
      // .playAndRecord; passing them here fails the whole call with -50.
      try audioSession.setCategory(.playback, mode: .moviePlayback)
      try audioSession.setActive(true)
    } catch {
      print("Failed to configure audio session for AirPlay: \(error)")
    }
  }
}
