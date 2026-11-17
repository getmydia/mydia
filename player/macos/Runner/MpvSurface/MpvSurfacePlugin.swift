import Cocoa
import FlutterMacOS

/// Hosts mpv's video output in a Flutter `AppKitView` on macOS, and makes
/// every mpv write that creates, changes or destroys that output.
///
/// mpv's mac video output does `DispatchQueue.main.sync` while it is created
/// and torn down, and Dart can run on the main thread, so a synchronous write
/// from Dart would deadlock. Every mpv call here runs on one serial
/// background queue, in arrival order, and replies hop back to main.
///
/// Method channel `mydia/mpv-surface`:
/// - `attach({handle, viewId, options}) -> null`: sets `wid` to the host
///   view, each `[name, value]` option in order, then `vid=auto`.
/// - `setOption({handle, name, value}) -> null`
/// - `awaitVideoOutput({handle}) -> {started}`: with a video track in
///   `track-list`, polls `current-vo` for up to 2 s; without one, `true`.
/// - `detach({handle}) -> null`: sets `vid=no` and waits up to 3 s for
///   `current-vo` to clear, logging if it does not.
///
/// Event channel `mydia/mpv-surface/display`:
/// `{edrHeadroom, potentialHeadroom, screenName}` for the window's screen.
final class MpvSurfacePlugin: NSObject, FlutterPlatformViewFactory, FlutterStreamHandler {
  static let channelName = "mydia/mpv-surface"
  static let displayChannelName = "mydia/mpv-surface/display"
  static let viewType = "mydia/mpv-surface"
  static let queueLabel = "dev.mydia.mpv-surface"
  static let startTimeout: TimeInterval = 2
  static let detachTimeout: TimeInterval = 3
  static let defaultPollInterval: TimeInterval = 0.05

  private let api: MpvApi
  private let queue: DispatchQueue
  private let now: () -> TimeInterval
  private let sleep: (TimeInterval) -> Void
  private let pollInterval: TimeInterval
  private let log: (String) -> Void

  /// Host views by platform view id, held weakly: Flutter owns them.
  private let views = NSMapTable<NSNumber, MpvHostView>.strongToWeakObjects()

  /// Host views kept alive until their detach completes. Main thread only.
  private var pendingDetach: [UUID: [MpvHostView]] = [:]

  private var methodChannel: FlutterMethodChannel?
  private var displayChannel: FlutterEventChannel?
  private var displaySink: FlutterEventSink?
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []

  init(
    api: MpvApi = LiveMpvApi.shared,
    queue: DispatchQueue = DispatchQueue(label: MpvSurfacePlugin.queueLabel),
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    pollInterval: TimeInterval = MpvSurfacePlugin.defaultPollInterval,
    log: @escaping (String) -> Void = { NSLog("MpvSurface: %@", $0) }
  ) {
    self.api = api
    self.queue = queue
    self.now = now
    self.sleep = sleep
    self.pollInterval = pollInterval
    self.log = log
    super.init()
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  /// Registers the view factory and both channels. The caller holds the
  /// returned plugin; the channels only hold it through their handlers.
  static func register(with registrar: FlutterPluginRegistrar, window: NSWindow)
    -> MpvSurfacePlugin
  {
    let plugin = MpvSurfacePlugin()
    registrar.register(plugin, withId: viewType)

    let methods = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger)
    methods.setMethodCallHandler { [weak plugin] call, result in
      guard let plugin else {
        result(FlutterMethodNotImplemented)
        return
      }
      plugin.handle(call, result: result)
    }
    plugin.methodChannel = methods

    let display = FlutterEventChannel(
      name: displayChannelName, binaryMessenger: registrar.messenger)
    display.setStreamHandler(plugin)
    plugin.displayChannel = display

    plugin.observeDisplay(of: window)
    return plugin
  }

  /// The queue every mpv call runs on, for tests that need to drain it.
  var queueForTesting: DispatchQueue { queue }

  // MARK: Method channel

  /// Runs on the main thread, where the platform channel delivers calls.
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    guard let handleValue = (args["handle"] as? NSNumber)?.intValue,
      let handle = OpaquePointer(bitPattern: handleValue)
    else {
      result(FlutterError(code: "bad-args", message: "\(call.method): missing handle", details: nil))
      return
    }

    switch call.method {
    case "attach":
      guard let viewId = (args["viewId"] as? NSNumber)?.int64Value,
        let view = views.object(forKey: NSNumber(value: viewId))
      else {
        result(FlutterError(code: "no-view", message: "attach: unknown viewId", details: nil))
        return
      }
      guard let options = Self.parseOptions(args["options"]) else {
        result(FlutterError(code: "bad-args", message: "attach: bad options", details: nil))
        return
      }
      // Read on main, before the hop: the view belongs to AppKit.
      let wid = String(Int(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
      // The newest view is the sole owner of the handle. Flutter can build
      // the replacement AppKitView (route change, fullscreen rebuild) before
      // it disposes the old one, and the old one leaving its window must not
      // detach the output that now lives in the new one.
      //
      // Reattaching this view to a different handle simply overwrites
      // `attachedHandle`: the previous handle's output is the caller's to
      // detach first, and leaving the window only detaches the latest.
      forgetAttachment(handleValue)
      view.attachedHandle = handleValue
      attach(handle, wid: wid, options: options) { result(nil) }

    case "setOption":
      guard let name = args["name"] as? String, let value = args["value"] as? String else {
        result(FlutterError(code: "bad-args", message: "setOption: name and value", details: nil))
        return
      }
      onQueue(reply: { result(nil) }) { self.set(handle, name, value) }

    case "awaitVideoOutput":
      awaitVideoOutput(handle) { started in result(["started": started]) }

    case "detach":
      let hosts = forgetAttachment(handleValue)
      detach(handle, keepingAlive: hosts) { result(nil) }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func parseOptions(_ raw: Any?) -> [(String, String)]? {
    guard let raw else { return [] }
    guard let list = raw as? [Any] else { return nil }
    var options: [(String, String)] = []
    for entry in list {
      guard let pair = entry as? [Any], pair.count == 2,
        let name = pair[0] as? String, let value = pair[1] as? String
      else { return nil }
      options.append((name, value))
    }
    return options
  }

  // MARK: mpv operations (all on `queue`)

  private func attach(
    _ handle: OpaquePointer, wid: String, options: [(String, String)],
    reply: @escaping () -> Void
  ) {
    onQueue(reply: reply) {
      self.set(handle, "wid", wid)
      for (name, value) in options { self.set(handle, name, value) }
      self.set(handle, "vid", "auto")
    }
  }

  private func awaitVideoOutput(_ handle: OpaquePointer, reply: @escaping (Bool) -> Void) {
    queue.async {
      let started: Bool
      if self.hasVideoTrack(handle) {
        started = self.poll(timeout: Self.startTimeout) {
          !(self.api.getString(handle, "current-vo") ?? "").isEmpty
        }
        if !started { self.log("video output did not start within \(Self.startTimeout)s") }
      } else {
        started = true
      }
      DispatchQueue.main.async { reply(started) }
    }
  }

  private func detach(_ handle: OpaquePointer, reply: @escaping () -> Void) {
    onQueue(reply: reply) {
      self.set(handle, "vid", "no")
      let cleared = self.poll(timeout: Self.detachTimeout) {
        (self.api.getString(handle, "current-vo") ?? "").isEmpty
      }
      if !cleared {
        self.log("detach timed out after \(Self.detachTimeout)s waiting for current-vo to clear")
      }
    }
  }

  /// Detaches while holding `hosts` strongly until the detach completes.
  ///
  /// `wid` is an unretained pointer and `views` is weak, so without this
  /// Flutter could free a host view while mpv's output teardown, which runs
  /// on main and removes mpv's subview from the `wid` view, is still queued.
  private func detach(
    _ handle: OpaquePointer, keepingAlive hosts: [MpvHostView], reply: @escaping () -> Void
  ) {
    let token = UUID()
    if !hosts.isEmpty { pendingDetach[token] = hosts }
    detach(handle) {
      self.pendingDetach[token] = nil
      reply()
    }
  }

  private func onQueue(reply: @escaping () -> Void, _ work: @escaping () -> Void) {
    queue.async {
      work()
      DispatchQueue.main.async(execute: reply)
    }
  }

  private func set(_ handle: OpaquePointer, _ name: String, _ value: String) {
    let code = api.setOption(handle, name, value)
    if code != 0 { log("set \(name)=\(value) failed: \(code)") }
  }

  private func hasVideoTrack(_ handle: OpaquePointer) -> Bool {
    guard let json = api.getString(handle, "track-list"),
      let data = json.data(using: .utf8),
      let tracks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return false }
    return tracks.contains { $0["type"] as? String == "video" }
  }

  /// Checks `done` every `pollInterval` until it holds or `timeout` passes.
  private func poll(timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let deadline = now() + timeout
    while true {
      if done() { return true }
      if now() >= deadline { return false }
      sleep(pollInterval)
    }
  }

  // MARK: Host views

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let view = MpvHostView(frame: .zero)
    view.onLeaveWindow = { [weak self, weak view] handleValue in
      guard let self, let handle = OpaquePointer(bitPattern: handleValue) else { return }
      let hosts = self.forgetAttachment(handleValue) + [view].compactMap { $0 }
      self.detach(handle, keepingAlive: hosts) {}
    }
    views.setObject(view, forKey: NSNumber(value: viewId))
    return view
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }

  /// Clears `handleValue` from every view that holds it, so no view starts
  /// a detach for it later, and returns those views.
  @discardableResult
  private func forgetAttachment(_ handleValue: Int) -> [MpvHostView] {
    var cleared: [MpvHostView] = []
    for case let view as MpvHostView in views.objectEnumerator()?.allObjects ?? []
    where view.attachedHandle == handleValue {
      view.attachedHandle = nil
      cleared.append(view)
    }
    return cleared
  }

  // MARK: Display reporting

  private func observeDisplay(of window: NSWindow) {
    self.window = window
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
      ) { [weak self] _ in self?.reportDisplay() })
    observers.append(
      center.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.reportDisplay() })
  }

  private func reportDisplay() {
    guard let sink = displaySink, let screen = window?.screen ?? NSScreen.main else { return }
    sink([
      "edrHeadroom": Double(screen.maximumExtendedDynamicRangeColorComponentValue),
      "potentialHeadroom": Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
      "screenName": screen.localizedName,
    ])
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    displaySink = events
    reportDisplay()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    displaySink = nil
    return nil
  }
}
