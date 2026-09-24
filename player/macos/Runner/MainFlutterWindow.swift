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
  /// double-clicks to Flutter only; Flutter decides whether the click hit
  /// empty band space and, if so, asks for the native action over the
  /// window_chrome channel (performTitleBarDoubleClick).
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

  /// The user's System Settings > Desktop & Dock "Double-click a window's
  /// title bar to" choice. Newer macOS writes AppleActionOnDoubleClick
  /// ("Maximize", "Minimize", "Fill", "None"); older releases only had the
  /// AppleMiniaturizeOnDoubleClick bool.
  func performTitleBarDoubleClick() {
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
