import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Height of the band the Flutter title row draws into.
  /// kMacTitleBarOverlap in lib/core/layout/window_chrome_inset.dart.
  private let titleBandHeight: CGFloat = 40

  /// Whether the left-click gesture currently in progress was diverted to
  /// Flutter at its `leftMouseDown`.
  ///
  /// Diversion is an all-or-nothing decision made once, at the down, not
  /// re-evaluated per event: `sendEvent` sees a `leftMouseDown`, zero or more
  /// `leftMouseDragged`, and a matching `leftMouseUp` as one gesture, and a
  /// gesture split across Flutter and AppKit is exactly the bug this guards
  /// against. Re-checking `isInTitleBand`/`clickCount` on the drag and the up
  /// (as an earlier version of this method did) let a drag wander out of the
  /// band, or the pointer come up somewhere `isOverTrafficLight` would now
  /// answer true for, and hand AppKit a `leftMouseDragged`/`leftMouseUp` with
  /// no matching down of its own -- enough for AppKit's own title bar to
  /// start a stray native window drag while Flutter is left holding a
  /// mouseDown that never gets its mouseUp. Set true on a qualifying down,
  /// stays true for every event until the matching up, which always reaches
  /// Flutter and always clears it, wherever the pointer ended up.
  private var routingClickToFlutter = false

  /// `ProcessInfo.processInfo.systemUptime` at the most recent diverted
  /// `leftMouseDown`, or nil once consumed (or if none has happened yet).
  ///
  /// Diversion already requires `clickCount >= 2` (see `sendEvent`), so
  /// recording it at all means AppKit counted that down as the second half
  /// of a double-click. `NSEvent.timestamp` shares the system-uptime clock
  /// with `ProcessInfo.processInfo.systemUptime`, so the two are directly
  /// comparable without going through wall-clock `Date`.
  ///
  /// `handleTitleBarPointerDown` is the only reader, and it always clears
  /// this after checking it -- a stale divert from an earlier, unrelated
  /// gesture must never be mistaken for a fresh one just because Flutter's
  /// report for it happened to arrive late.
  private var divertedDoubleClickAt: TimeInterval?

  /// How long a diverted double-click's `leftMouseDown` stays eligible to
  /// trigger the title bar action once Flutter reports the matching
  /// pointer-down back over the channel.
  ///
  /// Generous against `NSEvent.doubleClickInterval`'s own maximum (users can
  /// set it well past a second in Accessibility settings) since the cost of
  /// too generous a window is negligible -- the channel round trip normally
  /// lands in a few milliseconds -- while too tight a window reintroduces
  /// exactly the bug this file exists to fix.
  private let pointerDownReportWindow: TimeInterval = 0.5

  override func awakeFromNib() {
    // Set app-wide state here because MainMenu.xib instantiates this window,
    // so awakeFromNib runs during main nib load, before
    // AppDelegate.applicationDidFinishLaunching builds Sparkle and the menus.

    // The app is dark-only. Without this, AppKit-drawn pieces (Sparkle's
    // update windows, menus, alerts, the title bar during live resize and
    // fullscreen transitions) follow the system appearance and render light
    // on a light-mode Mac.
    NSApp.appearance = NSAppearance(named: .darkAqua)

    // Single-window app: drop "Show Tab Bar" and "Merge All Windows" from the
    // View menu.
    NSWindow.allowsAutomaticWindowTabbing = false

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Make the window look more native
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)

    // AppColors.background in lib/core/theme/colors.dart. Shown before the
    // first Flutter frame and in the gaps during live resize and fullscreen
    // transitions, which would otherwise flash the default light window colour.
    let appBackground = NSColor(
      srgbRed: 0x0B / 255.0,
      green: 0x0B / 255.0,
      blue: 0x0C / 255.0,
      alpha: 1
    )
    self.backgroundColor = appBackground
    flutterViewController.backgroundColor = appBackground

    // An empty unified compact toolbar gives the title bar the taller band
    // sidebar apps use, with the traffic lights inset from the corner.
    // kMacTitleBarOverlap in lib/core/layout/window_chrome_inset.dart must
    // match the band height.
    let toolbar = NSToolbar(identifier: "MainToolbar")
    self.toolbar = toolbar
    self.toolbarStyle = .unifiedCompact
    self.titlebarSeparatorStyle = .none

    // In fullscreen the empty toolbar would appear as a blank strip when the
    // menu bar slides down. WindowChromeInset already drops the inset there.
    let center = NotificationCenter.default
    center.addObserver(
      forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.toolbar?.isVisible = false }
    center.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.toolbar?.isVisible = true }

    super.awakeFromNib()
  }

  /// AppKit zooms the window on any double-click in the title bar, including
  /// one that lands on a Flutter control drawn there (back, cast). Route band
  /// double-clicks to Flutter only; Flutter reports every pointer-down that
  /// lands on empty band space over the window_chrome channel
  /// (titleBarPointerDown), and `handleTitleBarPointerDown` decides whether
  /// to run the native action.
  ///
  /// A qualifying `leftMouseDown` starts the diversion and every event up to
  /// and including its matching `leftMouseUp` follows it, regardless of
  /// where the pointer is by then -- see `routingClickToFlutter`.
  override func sendEvent(_ event: NSEvent) {
    guard let flutter = contentViewController else {
      super.sendEvent(event)
      return
    }

    if event.type == .leftMouseDown,
      event.clickCount >= 2,
      !styleMask.contains(.fullScreen),
      isInTitleBand(event.locationInWindow),
      !isOverTrafficLight(event.locationInWindow) {
      routingClickToFlutter = true
      divertedDoubleClickAt = event.timestamp
    }

    if routingClickToFlutter {
      switch event.type {
      case .leftMouseDown:
        flutter.mouseDown(with: event)
        return
      case .leftMouseDragged:
        flutter.mouseDragged(with: event)
        return
      case .leftMouseUp:
        routingClickToFlutter = false
        flutter.mouseUp(with: event)
        return
      default:
        break
      }
    }

    super.sendEvent(event)
  }

  private func isInTitleBand(_ point: NSPoint) -> Bool {
    guard let content = contentView else { return false }
    return point.y >= content.bounds.height - titleBandHeight
  }

  private func isOverTrafficLight(_ point: NSPoint) -> Bool {
    let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    return types.contains { type in
      guard let button = standardWindowButton(type), let superview = button.superview else {
        return false
      }
      return button.frame.contains(superview.convert(point, from: nil))
    }
  }

  /// Handles a `titleBarPointerDown` report from `WindowDragBand`: runs the
  /// title bar action if, and only if, the pointer-down being reported is the
  /// one `sendEvent` just diverted as the second half of a double-click.
  ///
  /// Flutter's `Listener.onPointerDown` fires on every pointer-down on empty
  /// band space, single clicks included, and reports every one of them here
  /// -- it has no way to know AppKit's `clickCount` itself. This is where
  /// that count is actually checked, via `divertedDoubleClickAt`: no record,
  /// or one older than `pointerDownReportWindow`, means this down was not a
  /// qualifying double-click (or the report arrived too late to trust), and
  /// nothing happens.
  ///
  /// The channel round trip is asynchronous, so this can run after
  /// `sendEvent` already reset `routingClickToFlutter` back to false for the
  /// completed gesture, sometimes after the matching `leftMouseUp` -- reading
  /// that flag here instead of `divertedDoubleClickAt` would always see it
  /// false and never act. The record is always cleared before returning, so
  /// a second report for the same divert (there should never be one, but
  /// Flutter's report is fire-and-forget) can never run the action twice.
  func handleTitleBarPointerDown() {
    defer { divertedDoubleClickAt = nil }
    guard let divertedAt = divertedDoubleClickAt,
      ProcessInfo.processInfo.systemUptime - divertedAt < pointerDownReportWindow
    else {
      return
    }
    performTitleBarDoubleClick()
  }

  /// The user's System Settings > Desktop & Dock "Double-click a window's
  /// title bar to" choice. Newer macOS writes AppleActionOnDoubleClick
  /// ("Maximize", "Minimize", "Fill", "None"); older releases only had the
  /// AppleMiniaturizeOnDoubleClick bool.
  ///
  /// Only called from `handleTitleBarPointerDown`, which is the sole gate on
  /// running this: nothing else -- in Dart or here -- decides on its own that
  /// a click qualifies.
  private func performTitleBarDoubleClick() {
    let defaults = UserDefaults.standard
    switch defaults.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      miniaturize(nil)
    case "None":
      break
    case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
      miniaturize(nil)
    default:
      zoom(nil)
    }
  }
}
