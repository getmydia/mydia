import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
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
    toolbar.showsBaselineSeparator = false
    self.toolbar = toolbar
    self.toolbarStyle = .unifiedCompact

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
}
