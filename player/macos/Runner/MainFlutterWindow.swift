import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Height of the band the Flutter title row draws into.
  /// kMacTitleBarOverlap in lib/core/layout/window_chrome_inset.dart.
  private let titleBandHeight: CGFloat = 40

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
  override func sendEvent(_ event: NSEvent) {
    if (event.type == .leftMouseDown || event.type == .leftMouseUp),
      event.clickCount >= 2,
      !styleMask.contains(.fullScreen),
      isInTitleBand(event.locationInWindow),
      !isOverTrafficLight(event.locationInWindow),
      let flutter = contentViewController {
      if event.type == .leftMouseDown {
        flutter.mouseDown(with: event)
      } else {
        flutter.mouseUp(with: event)
      }
      return
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
