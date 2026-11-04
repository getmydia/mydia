import Flutter
import UIKit
import AVFoundation
import CoreMedia
import VideoToolbox

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

    // Which of HEVC, VP9 and AV1 this device decodes in hardware. The Dart
    // profile drops the ones reported false so the server transcodes them
    // instead of mpv software-decoding on an A8-class iPad. Kept inline rather
    // than in its own file so the Xcode project needs no new file reference.
    if let codecRegistrar = registry.registrar(forPlugin: "CodecCapabilities") {
      FlutterMethodChannel(name: "dev.mydia.player/codecs",
                           binaryMessenger: codecRegistrar.messenger())
        .setMethodCallHandler { call, result in
          guard call.method == "hardwareVideoDecoders" else {
            result(FlutterMethodNotImplemented)
            return
          }
          result(AppDelegate.hardwareVideoDecoders())
        }
    }

    if let tabBarRegistrar = registry.registrar(forPlugin: "NativeTabBarPlugin") {
      nativeTabBarPlugin = NativeTabBarPlugin(messenger: tabBarRegistrar.messenger())
    }
  }

  /// `VTIsHardwareDecodeSupported` per codec. The VP9 and AV1 codec constants
  /// only exist from iOS 14 and 17; below that the codec cannot be decoded in
  /// hardware, so it reports false. The deployment target is iOS 15, so the
  /// iOS 14 check is always true but is kept to match the constant's API.
  private static func hardwareVideoDecoders() -> [String: Bool] {
    var vp9 = false
    if #available(iOS 14.0, *) {
      vp9 = VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
    }
    var av1 = false
    if #available(iOS 17.0, *) {
      av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
    return [
      "hevc": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
      "vp9": vp9,
      "av1": av1,
    ]
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
