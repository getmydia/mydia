import Cocoa
import FlutterMacOS

/// The window's content: the native sidebar pane and the Flutter pane.
///
/// The `FlutterViewController` is added once here and never moved, so the
/// engine's view stays in the window for the app's lifetime.
final class MydiaSplitViewController: NSSplitViewController {
  let flutter: FlutterViewController
  let sidebarItem: NSSplitViewItem
  private let contentItem: NSSplitViewItem

  /// The Flutter pane's view, the one `MainFlutterWindow` routes title band
  /// clicks to.
  var flutterView: NSView { flutter.view }

  /// Called with true when the sidebar collapses, false when it shows,
  /// whoever caused it (the toggle, a narrow window, or `setChromeVisible`).
  var onSidebarCollapsedChanged: ((Bool) -> Void)?

  /// The viewer's own choice, kept while a covering page forces a collapse.
  /// Stored separately from the split view's autosave, which would also
  /// remember a forced collapse and start the next launch collapsed.
  private var viewerCollapsed = UserDefaults.standard.bool(
    forKey: MydiaSplitViewController.viewerCollapsedKey) {
    didSet { UserDefaults.standard.set(viewerCollapsed, forKey: Self.viewerCollapsedKey) }
  }
  private static let viewerCollapsedKey = "MydiaSidebarViewerCollapsed"
  private var forcedCollapsed = false

  /// Whether a covering page (the player) has hidden the sidebar and toolbar.
  var chromeForcedHidden: Bool { forcedCollapsed }
  private var observation: NSKeyValueObservation?

  init(flutter: FlutterViewController, sidebar: NSViewController) {
    self.flutter = flutter
    sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.canCollapse = true
    // Collapse rather than refuse when a live resize drags the window
    // narrower than both panes' minimums.
    sidebarItem.canCollapseFromWindowResize = true
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 320
    contentItem = NSSplitViewItem(viewController: flutter)
    // AppKit collapses the sidebar only when the content pane's minimum
    // cannot be met, so this floor is what makes a narrow window collapse it.
    contentItem.minimumThickness = 480
    super.init(nibName: nil, bundle: nil)
    addSplitViewItem(sidebarItem)
    addSplitViewItem(contentItem)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    splitView.autosaveName = "MydiaSidebar"
    observation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
      guard let self else { return }
      if !self.forcedCollapsed { self.viewerCollapsed = item.isCollapsed }
      self.onSidebarCollapsedChanged?(item.isCollapsed)
    }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if !forcedCollapsed { sidebarItem.isCollapsed = viewerCollapsed }
    // A first launch has no autosaved width; start at 240.
    if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MydiaSidebar") == nil {
      splitView.setPosition(240, ofDividerAt: 0)
    }
  }

  /// False collapses the sidebar and hides the toolbar (its toggle) for a
  /// page that covers the shell, the player; true restores whatever the
  /// viewer had.
  func setChromeVisible(_ visible: Bool) {
    if visible {
      guard forcedCollapsed else { return }
      forcedCollapsed = false
      setToolbarVisible(true)
      sidebarItem.animator().isCollapsed = viewerCollapsed
    } else {
      guard !forcedCollapsed else { return }
      forcedCollapsed = true
      setToolbarVisible(false)
      sidebarItem.animator().isCollapsed = true
    }
  }

  /// Fullscreen hides the toolbar on its own (`MainFlutterWindow`), so leave
  /// it hidden there.
  private func setToolbarVisible(_ visible: Bool) {
    guard let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
    window.toolbar?.isVisible = visible
  }
}
