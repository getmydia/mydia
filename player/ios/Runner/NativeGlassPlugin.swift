import Flutter
import UIKit

/// Native Liquid Glass for `NativeGlass` (lib/presentation/widgets/native_glass.dart).
///
/// Registers the `mydia/native-glass` platform view and a channel of the same
/// name whose only method, `isSupported`, tells Dart whether to use it. The
/// glass is a background shape only: it never takes touches, and every row,
/// icon and label on it stays in Flutter.
final class NativeGlassPlugin: NSObject, FlutterPlugin {
  static let name = "mydia/native-glass"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NativeGlassPlugin(), channel: channel)
    registrar.register(NativeGlassViewFactory(), withId: name)
  }

  /// True only when built with the iOS 26 SDK and running on iOS 26+.
  static var isSupported: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported": result(Self.isSupported)
    default: result(FlutterMethodNotImplemented)
    }
  }
}

private final class NativeGlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeGlassPlatformView(frame: frame, params: NativeGlassParams(args))
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Creation params sent by `NativeGlass._creationParams`.
private struct NativeGlassParams {
  let cornerRadius: CGFloat
  let tint: UIColor?
  let clear: Bool

  init(_ args: Any?) {
    let map = args as? [String: Any] ?? [:]
    cornerRadius = CGFloat((map["cornerRadius"] as? NSNumber)?.doubleValue ?? 0)
    tint = (map["tint"] as? NSNumber).map {
      UIColor(argb: UInt32(truncatingIfNeeded: $0.int64Value))
    }
    clear = (map["style"] as? String) == "clear"
  }
}

private final class NativeGlassPlatformView: NSObject, FlutterPlatformView {
  private let effectView = UIVisualEffectView(effect: nil)

  init(frame: CGRect, params: NativeGlassParams) {
    super.init()
    effectView.frame = frame
    effectView.isUserInteractionEnabled = false
    effectView.clipsToBounds = true
    effectView.layer.cornerRadius = params.cornerRadius
    effectView.layer.cornerCurve = .continuous
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: params.clear ? .clear : .regular)
      glass.tintColor = params.tint
      effectView.effect = glass
    }
    #endif
  }

  func view() -> UIView { effectView }
}

private extension UIColor {
  /// A Dart `Color.toARGB32()` value.
  convenience init(argb: UInt32) {
    self.init(
      red: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }
}
