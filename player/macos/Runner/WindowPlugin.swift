import Cocoa
import FlutterMacOS

/// The app window, served to Dart over `dev.mydia.player/window`.
///
/// Dart runs off the main thread on macOS (`FLTEnableMergedPlatformUIThread`
/// is false, for mpv; see `player/docs/playback.md`). window_manager 0.7's
/// nativeapi calls AppKit from the calling thread, so from there it cannot
/// even find this window. Channel handlers run on the main thread, which is
/// where AppKit has to be called. Nothing here touches mpv.
///
/// Matched by `kMacWindowChannelName` in
/// `lib/core/window/window_chrome_channel.dart` and decoded by
/// `lib/core/window/mac_window_channel.dart`.
///
/// Rects cross the channel with a top-left origin measured from the primary
/// screen (`NSScreen.screens[0]`), as nativeapi reported them, so geometry
/// saved by earlier builds stays valid.
final class WindowPlugin: NSObject {
  static let channelName = "dev.mydia.player/window"

  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []

  /// The last maximized state sent, so a resize that zooms or unzooms is
  /// reported once. AppKit has no zoom notification.
  private var lastMaximized = false

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    self.window = window
    super.init()
    lastMaximized = Self.isMaximized(window)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    observe(window)
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  // MARK: Coordinates

  /// An AppKit frame (bottom-left origin) as a top-left rect on the primary
  /// screen's axis.
  static func topLeftRect(_ frame: NSRect, primaryHeight: CGFloat) -> NSRect {
    NSRect(
      x: frame.origin.x,
      y: primaryHeight - frame.origin.y - frame.size.height,
      width: frame.size.width,
      height: frame.size.height)
  }

  /// The inverse of [topLeftRect]. The conversion is its own inverse.
  static func appKitFrame(_ rect: NSRect, primaryHeight: CGFloat) -> NSRect {
    topLeftRect(rect, primaryHeight: primaryHeight)
  }

  /// Locks user resizes to [ratio] (width / height); 0 clears the lock.
  ///
  /// Never `contentAspectRatio = .zero`: AppKit divides by it when it
  /// restores the frame on leaving fullscreen, and the resulting frame raises
  /// NSInternalInconsistencyException in `_reallySetFrame`. The sizer drops
  /// its lock on entering fullscreen, so that is exactly the path it took.
  /// `contentResizeIncrements` and `contentAspectRatio` are mutually
  /// exclusive: setting 1x1 increments is AppKit's way to clear the ratio.
  static func applyAspectRatio(_ ratio: Double, to window: NSWindow) {
    if ratio > 0 {
      window.contentAspectRatio = NSSize(width: ratio, height: 1)
    } else {
      window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
  }

  private static var primaryHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? 0
  }

  private static func encode(_ rect: NSRect) -> [String: Double] {
    [
      "x": Double(rect.origin.x), "y": Double(rect.origin.y),
      "width": Double(rect.size.width), "height": Double(rect.size.height),
    ]
  }

  private static func decodeRect(_ raw: Any?) -> NSRect? {
    guard let map = raw as? [String: Any],
      let x = (map["x"] as? NSNumber)?.doubleValue,
      let y = (map["y"] as? NSNumber)?.doubleValue,
      let width = (map["width"] as? NSNumber)?.doubleValue,
      let height = (map["height"] as? NSNumber)?.doubleValue
    else { return nil }
    return NSRect(x: x, y: y, width: width, height: height)
  }

  private static func isFullScreen(_ window: NSWindow) -> Bool {
    window.styleMask.contains(.fullScreen)
  }

  /// Zoomed and on screen, as nativeapi defined it: a miniaturized or
  /// fullscreen window is not "maximized".
  private static func isMaximized(_ window: NSWindow) -> Bool {
    window.isZoomed && !window.isMiniaturized && !isFullScreen(window)
  }

  // MARK: Calls from Dart

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Work areas need no window.
    if call.method == "getWorkAreas" {
      let height = Self.primaryHeight
      result(
        NSScreen.screens.enumerated().map { index, screen in
          var area: [String: Any] = Self.encode(
            Self.topLeftRect(screen.visibleFrame, primaryHeight: height))
          area["isPrimary"] = index == 0
          return area
        })
      return
    }

    guard let window = window else {
      result(FlutterError(code: "no_window", message: "The app window is gone", details: nil))
      return
    }
    let args = call.arguments as? [String: Any]

    switch call.method {
    case "getBounds":
      result(Self.encode(Self.topLeftRect(window.frame, primaryHeight: Self.primaryHeight)))
    case "setBounds":
      guard let rect = Self.decodeRect(call.arguments) else {
        return result(badArgs(call))
      }
      window.setFrame(Self.appKitFrame(rect, primaryHeight: Self.primaryHeight), display: true)
      result(nil)
    case "isMaximized":
      result(Self.isMaximized(window))
    case "isFullScreen":
      result(Self.isFullScreen(window))
    case "maximize":
      if !window.isZoomed { window.zoom(nil) }
      result(nil)
    case "unmaximize":
      if window.isZoomed { window.zoom(nil) }
      result(nil)
    case "minimize":
      window.miniaturize(nil)
      result(nil)
    case "close":
      window.performClose(nil)
      result(nil)
    case "enterFullScreen":
      if !Self.isFullScreen(window) { window.toggleFullScreen(nil) }
      result(nil)
    case "exitFullScreen":
      if Self.isFullScreen(window) { window.toggleFullScreen(nil) }
      result(nil)
    case "setMinimumSize":
      guard let width = (args?["width"] as? NSNumber)?.doubleValue,
        let height = (args?["height"] as? NSNumber)?.doubleValue
      else { return result(badArgs(call)) }
      window.minSize = NSSize(width: width, height: height)
      result(nil)
    case "setAspectRatio":
      guard let ratio = (args?["ratio"] as? NSNumber)?.doubleValue else {
        return result(badArgs(call))
      }
      Self.applyAspectRatio(ratio, to: window)
      result(nil)
    case "startDragging":
      if let event = NSApp.currentEvent { window.performDrag(with: event) }
      result(nil)
    case "setAlwaysOnTop":
      guard let value = args?["value"] as? Bool else { return result(badArgs(call)) }
      window.level = value ? .floating : .normal
      result(nil)
    case "raise":
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func badArgs(_ call: FlutterMethodCall) -> FlutterError {
    FlutterError(
      code: "bad_args", message: "Bad arguments for \(call.method)", details: call.arguments)
  }

  // MARK: Events to Dart

  private func observe(_ window: NSWindow) {
    let center = NotificationCenter.default
    func on(_ name: Notification.Name, _ handler: @escaping () -> Void) {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { _ in handler() })
    }
    on(NSWindow.didResizeNotification) { [weak self] in self?.resized() }
    on(NSWindow.didMoveNotification) { [weak self] in self?.send("moved") }
    on(NSWindow.didEnterFullScreenNotification) { [weak self] in
      self?.send("enteredFullScreen")
    }
    on(NSWindow.didExitFullScreenNotification) { [weak self] in
      self?.send("exitedFullScreen")
    }
    on(NSWindow.didMiniaturizeNotification) { [weak self] in self?.send("minimized") }
    on(NSWindow.didDeminiaturizeNotification) { [weak self] in self?.restored() }
    on(NSWindow.willCloseNotification) { [weak self] in self?.send("closeRequested") }
  }

  private func send(_ event: String, _ arguments: Any? = nil) {
    channel.invokeMethod(event, arguments: arguments)
  }

  private func resized() {
    send("resized")
    guard let window = window else { return }
    let maximized = Self.isMaximized(window)
    if maximized != lastMaximized {
      lastMaximized = maximized
      send(maximized ? "maximized" : "unmaximized")
    }
  }

  private func restored() {
    guard let window = window else { return }
    lastMaximized = Self.isMaximized(window)
    send("restored", ["maximized": lastMaximized])
  }
}
