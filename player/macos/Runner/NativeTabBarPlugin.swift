import Cocoa
import FlutterMacOS

/// Owns `mydia/native-tab-bar` on macOS (see player/docs/native-tab-bar.md).
/// Same contract as iOS; the macOS sidebar is always a pane, so `layout`
/// is always the sidebar and `layoutChanged` is never sent.
final class NativeTabBarPlugin: NSObject {
  static let channelName = "mydia/native-tab-bar"

  private let channel: FlutterMethodChannel
  private weak var split: MydiaSplitViewController?
  private weak var sidebar: MydiaSidebarViewController?
  private weak var window: NSWindow?
  private var loggedIgnored: Set<String> = []
  private var lastChrome: Double?
  private var observers: [NSObjectProtocol] = []
  /// Registered with the distributed center, so removed from that one.
  private var accentObserver: NSObjectProtocol?
  /// Registered with the workspace center, so removed from that one.
  private var accessibilityObserver: NSObjectProtocol?
  /// The View menu items `installCommands` added, removed on the next call.
  private var viewMenuItems: [NSMenuItem] = []

  init(
    messenger: FlutterBinaryMessenger, split: MydiaSplitViewController,
    sidebar: MydiaSidebarViewController, window: NSWindow
  ) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    self.split = split
    self.sidebar = sidebar
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    sidebar.onSelect = { [weak self] id in
      self?.channel.invokeMethod("tabSelected", arguments: id)
    }
    split.onSidebarCollapsedChanged = { [weak self] _ in self?.reportInsets() }

    // A collapse animates the Flutter pane's frame and the toolbar moves the
    // toggle as it goes, so measure on every frame change rather than at the
    // collapse callback, which fires before the pane has moved.
    let center = NotificationCenter.default
    let flutterView = split.flutterView
    flutterView.postsFrameChangedNotifications = true
    observers.append(
      center.addObserver(
        forName: NSView.frameDidChangeNotification, object: flutterView, queue: .main
      ) { [weak self] _ in self?.reportInsets() })
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          self?.reportInsets()
        })
    }

    // The accent the sidebar's selection uses, so Flutter's macOS theme can
    // match it. Accent changes post the system-colours notification; the
    // distributed one is the documented fallback on releases that skip it.
    let reportAccent: (Notification) -> Void = { [weak self] _ in
      self?.channel.invokeMethod("systemAccentChanged", arguments: Self.accentARGB())
    }
    observers.append(
      center.addObserver(
        forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main,
        using: reportAccent))
    accentObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("AppleColorPreferencesChangedNotification"),
      object: nil, queue: .main, using: reportAccent)

    // Reduce Transparency and Increase Contrast, for the Flutter glass.
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.channel.invokeMethod(
        "glassAccessibilityChanged", arguments: Self.glassAccessibility())
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    if let accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
    }
    if let accentObserver {
      DistributedNotificationCenter.default().removeObserver(accentObserver)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "mode":
      // A fresh Dart isolate (first launch, hot restart) asks this first and
      // has missed any earlier report, so the next one must go out.
      lastChrome = nil
      result("sidebar")
    case "isSupported": result(true)
    case "layout": result(["sidebar": true])
    case "setSidebar":
      sidebar?.apply(SidebarModel(payload: call.arguments))
      installCommands()
      // The first report goes out on the Flutter view's first frame change,
      // before Dart listens; resend so Dart's insets are never left null.
      lastChrome = nil
      reportInsets()
      result(nil)
    case "select":
      sidebar?.select(call.arguments as? String)
      result(nil)
    case "setVisible":
      split?.setChromeVisible((call.arguments as? Bool) ?? true)
      result(nil)
    case "systemAccent":
      result(Self.accentARGB())
    case "glassAccessibility":
      result(Self.glassAccessibility())
    case "setWindowBackground":
      if let argb = call.arguments as? Int {
        let color = Self.color(argb: argb)
        window?.backgroundColor = color
        split?.flutter.backgroundColor = color
      }
      result(nil)
    case "setTabs", "setAccessory":
      if loggedIgnored.insert(call.method).inserted {
        NSLog("[NativeTabBar] %@ ignored on macOS", call.method)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Puts the sidebar's commands (Edit sidebar) at the top of the View menu.
  private func installCommands() {
    guard
      let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu
    else { return }
    viewMenuItems.forEach(viewMenu.removeItem)
    viewMenuItems = []
    // AppKit retitles it Show/Hide Sidebar as the pane changes.
    let toggle = NSMenuItem(
      title: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)),
      keyEquivalent: "s")
    toggle.keyEquivalentModifierMask = [.command, .control]
    viewMenuItems.append(toggle)
    for spec in sidebar?.commands ?? [] {
      let item = NSMenuItem(
        title: "\(spec.title)…", action: #selector(commandChosen(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = spec.id
      viewMenuItems.append(item)
    }
    viewMenuItems.append(.separator())
    for (index, item) in viewMenuItems.enumerated() {
      viewMenu.insertItem(item, at: index)
    }
  }

  @objc private func commandChosen(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { sidebar?.perform(command: id) }
  }

  /// The width of the Flutter pane's title band, from its leading edge, that
  /// window chrome covers: the traffic lights and the sidebar toggle while
  /// the sidebar is collapsed, 0 while it shows and in fullscreen.
  func reportInsets() {
    guard let split, let window else { return }
    var covered: CGFloat = 0
    if split.sidebarItem.isCollapsed, !window.styleMask.contains(.fullScreen) {
      let flutterView = split.flutterView
      let flutterMinX = flutterView.convert(flutterView.bounds, to: nil).minX
      var maxX: CGFloat = 0
      for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        if let button = window.standardWindowButton(type), let superview = button.superview {
          maxX = max(maxX, superview.convert(button.frame, to: nil).maxX)
        }
      }
      maxX = max(maxX, toggleMaxX(in: window) ?? 0)
      // The same 9pt gap kMacTrafficLightsWidth keeps, only when the chrome
      // reaches into the pane at all.
      if maxX > flutterMinX { covered = maxX - flutterMinX + 9 }
    }
    let chrome = Double(covered)
    guard chrome != lastChrome else { return }
    lastChrome = chrome
    channel.invokeMethod(
      "insetsChanged",
      arguments: ["top": 0.0, "leading": 0.0, "bottom": 0.0, "chromeLeading": chrome])
  }

  /// The trailing edge, in window coordinates, of the toolbar's sidebar
  /// toggle. AppKit builds the system item without a public `view`, so find
  /// its button in the title bar by its action.
  private func toggleMaxX(in window: NSWindow) -> CGFloat? {
    if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == .toggleSidebar }),
      let view = item.view, let superview = view.superview
    {
      return superview.convert(view.frame, to: nil).maxX
    }
    guard let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview
    else { return nil }
    return findToggle(in: titlebar).map { $0.convert($0.bounds, to: nil).maxX }
  }

  /// Reduce Transparency and Increase Contrast, for the Flutter glass.
  static func glassAccessibility() -> [String: Bool] {
    let workspace = NSWorkspace.shared
    return [
      "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
      "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
    ]
  }

  /// `controlAccentColor` as sRGB ARGB, resolved under the dark appearance
  /// the app forces (MainFlutterWindow).
  private static func accentARGB() -> Int {
    var argb = 0xFF0A_84FF
    (NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing())
      .performAsCurrentDrawingAppearance {
        guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        argb =
          (0xFF << 24) | (byte(c.redComponent) << 16)
          | (byte(c.greenComponent) << 8) | byte(c.blueComponent)
      }
    return argb
  }

  private static func color(argb: Int) -> NSColor {
    NSColor(
      srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
      green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255,
      alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }

  private func findToggle(in view: NSView) -> NSView? {
    if let control = view as? NSControl, !control.isHidden,
      control.action == #selector(NSSplitViewController.toggleSidebar(_:))
    {
      return control
    }
    for subview in view.subviews {
      if let found = findToggle(in: subview) { return found }
    }
    return nil
  }
}

extension NativeTabBarPlugin: NSMenuItemValidation {
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let id = menuItem.representedObject as? String else { return true }
    return sidebar?.commands.first(where: { $0.id == id })?.enabled ?? false
  }
}
