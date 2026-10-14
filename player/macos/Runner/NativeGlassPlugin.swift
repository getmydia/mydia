import Cocoa
import FlutterMacOS

/// Native Liquid Glass for `NativeGlass` (lib/presentation/widgets/native_glass.dart).
///
/// The macOS twin of ios/Runner/NativeGlassPlugin.swift: same view type,
/// channel and creation params, on `NSGlassEffectView`. The view returns nil
/// from `hitTest`, so every click lands on the Flutter content drawn over it.
final class NativeGlassPlugin: NSObject, FlutterPlugin {
  static let name = "mydia/native-glass"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(NativeGlassPlugin(), channel: channel)
    registrar.register(NativeGlassViewFactory(), withId: name)
  }

  /// True only when built with the macOS 26 SDK and running on macOS 26+.
  static var isSupported: Bool {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) { return true }
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
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let params = args as? [String: Any] ?? [:]
    let cornerRadius = CGFloat((params["cornerRadius"] as? NSNumber)?.doubleValue ?? 0)
    let tint = (params["tint"] as? NSNumber).map {
      NSColor(argb: UInt32(truncatingIfNeeded: $0.int64Value))
    }
    let clear = (params["style"] as? String) == "clear"

    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      let glass = PassThroughGlassView()
      glass.cornerRadius = cornerRadius
      glass.tintColor = tint
      glass.style = clear ? .clear : .regular
      return glass
    }
    #endif
    // Dart only creates this view when isSupported is true, so this is
    // unreachable in practice; an empty view keeps the contract total.
    return PassThroughView()
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private final class PassThroughGlassView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

private final class PassThroughView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSColor {
  /// A Dart `Color.toARGB32()` value.
  convenience init(argb: UInt32) {
    self.init(
      srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255
    )
  }
}
