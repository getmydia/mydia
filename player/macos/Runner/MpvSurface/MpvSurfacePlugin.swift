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
/// - `awaitVideoOutput({handle}) -> {started, failed}`: with a video track
///   in `track-list`, polls for up to 2 s until `current-vo` is set
///   (`started`) or mpv deselects the video track (`failed`); both false
///   means it timed out. Without a video track, `started` at once.
/// - `detach({handle}) -> null`: sets `vid=no` and waits up to 3 s for
///   `current-vo` to clear, logging if it does not.
///
/// Event channel `mydia/mpv-surface/display`:
/// `{edrHeadroom, potentialHeadroom, screenName}` for the window's screen,
/// sent on listen, on a screen change, and, while any host view is
/// attached, whenever a once-a-second re-read finds it changed. macOS moves
/// the current headroom on its own (it rises once EDR content is on screen
/// and follows brightness) without posting any notification.
final class MpvSurfacePlugin: NSObject, FlutterPlatformViewFactory, FlutterStreamHandler {
  static let channelName = "mydia/mpv-surface"
  static let displayChannelName = "mydia/mpv-surface/display"
  static let viewType = "mydia/mpv-surface"
  static let queueLabel = "dev.mydia.mpv-surface"
  static let startTimeout: TimeInterval = 2
  static let detachTimeout: TimeInterval = 3
  static let defaultPollInterval: TimeInterval = 0.05
  static let displayRefreshInterval: TimeInterval = 1
  /// Headroom moves smaller than this are not worth an event.
  static let headroomTolerance = 0.01

  /// What the display event channel reports.
  struct DisplayInfo: Equatable {
    var edrHeadroom: Double
    var potentialHeadroom: Double
    var screenName: String

    func differs(from other: DisplayInfo) -> Bool {
      screenName != other.screenName
        || abs(edrHeadroom - other.edrHeadroom) > MpvSurfacePlugin.headroomTolerance
        || abs(potentialHeadroom - other.potentialHeadroom) > MpvSurfacePlugin.headroomTolerance
    }

    var event: [String: Any] {
      [
        "edrHeadroom": edrHeadroom, "potentialHeadroom": potentialHeadroom,
        "screenName": screenName,
      ]
    }
  }

  /// Starts a repeating main-thread timer and returns the function that
  /// stops it.
  typealias ScheduleTimer = (TimeInterval, @escaping () -> Void) -> () -> Void

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

  /// Reads the display info; nil falls back to the window's screen.
  private let displayInfoOverride: (() -> DisplayInfo?)?
  private let scheduleTimer: ScheduleTimer
  /// Stops the headroom refresh timer; non-nil while it runs. Main only.
  private var stopDisplayRefresh: (() -> Void)?
  /// The last info sent, so the timer only sends changes. Main only.
  private var lastDisplayInfo: DisplayInfo?

  init(
    api: MpvApi = LiveMpvApi.shared,
    queue: DispatchQueue = DispatchQueue(label: MpvSurfacePlugin.queueLabel),
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    pollInterval: TimeInterval = MpvSurfacePlugin.defaultPollInterval,
    log: @escaping (String) -> Void = { NSLog("MpvSurface: %@", $0) },
    displayInfo: (() -> DisplayInfo?)? = nil,
    scheduleTimer: @escaping ScheduleTimer = MpvSurfacePlugin.mainRunLoopTimer
  ) {
    self.api = api
    self.queue = queue
    self.now = now
    self.sleep = sleep
    self.pollInterval = pollInterval
    self.log = log
    self.displayInfoOverride = displayInfo
    self.scheduleTimer = scheduleTimer
    super.init()
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    stopDisplayRefresh?()
  }

  /// A `Timer` on the main run loop in common modes, so it keeps ticking
  /// while a menu is open or the window is being resized.
  static func mainRunLoopTimer(_ interval: TimeInterval, _ tick: @escaping () -> Void)
    -> () -> Void
  {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    return { timer.invalidate() }
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
      updateDisplayRefresh()
      attach(handle, wid: wid, options: options) { result(nil) }

    case "setOption":
      guard let name = args["name"] as? String, let value = args["value"] as? String else {
        result(FlutterError(code: "bad-args", message: "setOption: name and value", details: nil))
        return
      }
      onQueue(reply: { result(nil) }) { self.set(handle, name, value) }

    case "awaitVideoOutput":
      awaitVideoOutput(handle) { outcome in result(outcome.reply) }

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

  /// How a start check ended.
  enum VideoOutputStart {
    /// `current-vo` is set, or there is no video to output.
    case started
    /// mpv deselected the video track, which is how it gives up on a video
    /// output that failed to initialize.
    case failed
    /// Neither within `startTimeout`: possibly just a slow start.
    case timedOut

    var reply: [String: Bool] { ["started": self == .started, "failed": self == .failed] }
  }

  private func awaitVideoOutput(
    _ handle: OpaquePointer, reply: @escaping (VideoOutputStart) -> Void
  ) {
    queue.async {
      var outcome = VideoOutputStart.started
      if !self.videoTracks(handle).isEmpty {
        let settled = self.poll(timeout: Self.startTimeout) {
          if !(self.api.getString(handle, "current-vo") ?? "").isEmpty {
            outcome = .started
            return true
          }
          if self.videoDeselected(handle) {
            outcome = .failed
            return true
          }
          return false
        }
        if !settled { outcome = .timedOut }
        switch outcome {
        case .started: break
        case .failed: self.log("mpv deselected the video track: the video output failed")
        case .timedOut: self.log("video output did not start within \(Self.startTimeout)s")
        }
      }
      DispatchQueue.main.async { reply(outcome) }
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

  /// The video entries of `track-list`; empty when it is unreadable.
  private func videoTracks(_ handle: OpaquePointer) -> [[String: Any]] {
    guard let json = api.getString(handle, "track-list"),
      let data = json.data(using: .utf8),
      let tracks = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return [] }
    return tracks.filter { $0["type"] as? String == "video" }
  }

  /// mpv's signal that the video output failed to initialize: it deselects
  /// the video track, so `vid` reads `no`, or the track is still listed but
  /// none is selected.
  private func videoDeselected(_ handle: OpaquePointer) -> Bool {
    if api.getString(handle, "vid") == "no" { return true }
    let video = videoTracks(handle)
    return !video.isEmpty && !video.contains { $0["selected"] as? Bool == true }
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
    updateDisplayRefresh()
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

  private func currentDisplayInfo() -> DisplayInfo? {
    if let displayInfoOverride { return displayInfoOverride() }
    guard let screen = window?.screen ?? NSScreen.main else { return nil }
    return DisplayInfo(
      edrHeadroom: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
      potentialHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
      screenName: screen.localizedName)
  }

  /// Sends the current info. `onlyIfChanged` is the timer's path: it stays
  /// quiet unless the screen or a headroom moved past the tolerance.
  private func reportDisplay(onlyIfChanged: Bool = false) {
    guard let sink = displaySink, let info = currentDisplayInfo() else { return }
    if onlyIfChanged, let last = lastDisplayInfo, !info.differs(from: last) { return }
    lastDisplayInfo = info
    sink(info.event)
  }

  /// Runs the refresh timer while any host view holds an attachment.
  private func updateDisplayRefresh() {
    let attached = (views.objectEnumerator()?.allObjects ?? []).contains {
      ($0 as? MpvHostView)?.attachedHandle != nil
    }
    if attached, stopDisplayRefresh == nil {
      stopDisplayRefresh = scheduleTimer(Self.displayRefreshInterval) { [weak self] in
        guard let self else { return }
        // An attached view Flutter freed without it leaving a window
        // (views is weak) stops the timer here instead of at a detach.
        self.updateDisplayRefresh()
        guard self.stopDisplayRefresh != nil else { return }
        self.reportDisplay(onlyIfChanged: true)
      }
    } else if !attached, let stop = stopDisplayRefresh {
      stop()
      stopDisplayRefresh = nil
    }
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
    lastDisplayInfo = nil
    return nil
  }
}
