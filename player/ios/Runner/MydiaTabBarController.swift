#if compiler(>=6.2)
import Flutter
import UIKit

/// One tab, as Dart's `NativeTab.toMap` sends it.
struct NativeTabSpec: Equatable {
  let id: String
  let title: String
  let symbol: String
  let badge: String?
  let enabled: Bool
}

extension NativeTabSpec {
  init?(channelValue: Any?) {
    guard let map = channelValue as? [String: Any],
          let id = map["id"] as? String,
          let title = map["title"] as? String,
          let symbol = map["symbol"] as? String else { return nil }
    self.init(
      id: id,
      title: title,
      symbol: symbol,
      badge: map["badge"] as? String,
      enabled: (map["enabled"] as? Bool) ?? true
    )
  }
}

/// One sidebar section, as Dart's `NativeSidebarSection.toMap` sends it.
/// Each item's `kind` only matters to Dart, so `NativeTabSpec` ignores it.
struct NativeSidebarSectionSpec: Equatable {
  let id: String
  let title: String?
  let items: [NativeTabSpec]
}

extension NativeSidebarSectionSpec {
  init?(channelValue: Any?) {
    guard let map = channelValue as? [String: Any],
          let id = map["id"] as? String,
          let items = map["items"] as? [Any] else { return nil }
    self.init(
      id: id,
      title: map["title"] as? String,
      items: items.compactMap(NativeTabSpec.init(channelValue:))
    )
  }
}

/// A real tab bar over the Flutter view on iOS 26 iPhones, and a real
/// sidebar on iOS 26 iPads.
///
/// Flutter draws every screen. This controller is a sibling above the
/// `FlutterViewController`, both children of `MydiaRootViewController`, and
/// never holds Flutter itself: `UITabBarController` owns its view's subviews
/// and drops any it did not add, which took the Flutter view out of the
/// window. Each tab hosts an empty, clear controller, and the root routes
/// every touch outside the chrome to Flutter (`hitTestBar`).
///
/// On an iPad (`usesSidebar`) it runs in `.tabSidebar` mode through the
/// `UITab` API: Dart sends sections with `setSidebar` at regular width and
/// the phone's flat tabs with `setTabs` at compact width, where iPadOS shows
/// a tab bar. The width class is reported through `onLayoutChanged`. The
/// iPhone keeps the view-controller API.
///
/// Flutter's route decides the selection. A tap is reported through
/// `onTabSelected` and refused here; Dart navigates and answers with `select`.
@available(iOS 26.0, *)
final class MydiaTabBarController: UITabBarController, UITabBarControllerDelegate {
  var onTabSelected: ((String) -> Void)?
  /// (top, leading, bottom) in points, all zero while the chrome is hidden.
  var onInsetsChanged: ((Double, Double, Double) -> Void)?
  /// True at regular width, where the sidebar shows.
  var onLayoutChanged: ((Bool) -> Void)?
  var onAccessoryTapped: (() -> Void)?
  var onAccessoryPlayPause: (() -> Void)?

  /// An iPad: the `UITab` API in `.tabSidebar` mode.
  let usesSidebar: Bool

  private var specs: [NativeTabSpec] = []
  private var sidebarSections: [NativeSidebarSectionSpec] = []
  private var tabsById: [String: UITab] = [:]
  private var selectedId: String?
  private var barVisible = false
  private var accessoryModel: CastAccessoryModel?
  private var lastReportedInsets: [Double]?
  private var lastReportedLayout: Bool?

  private lazy var accessoryView: CastAccessoryView = {
    let view = CastAccessoryView()
    view.onTap = { [weak self] in self?.onAccessoryTapped?() }
    view.onPlayPause = { [weak self] in self?.onAccessoryPlayPause?() }
    return view
  }()

  private lazy var accessory = UITabAccessory(contentView: accessoryView)

  init(usesSidebar: Bool = UIDevice.current.userInterfaceIdiom == .pad) {
    self.usesSidebar = usesSidebar
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    overrideUserInterfaceStyle = .dark
    tabBarMinimizeBehavior = .never
    // Flutter draws beneath this view; anything opaque here hides it.
    view.backgroundColor = .clear

    // Hidden until Dart asks for it, so a launch that never reaches the shell
    // (login, startup errors) shows no empty chrome.
    if usesSidebar {
      mode = .tabSidebar
      view.alpha = 0
      registerForTraitChanges([UITraitHorizontalSizeClass.self]) {
        (self: Self, _: UITraitCollection) in
        self.reportLayout()
      }
    } else {
      setTabBarHidden(true, animated: false)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    reportInsets()
    reportLayout()
  }

  /// True at regular width on an iPad, where the sidebar shows.
  var isSidebarLayout: Bool {
    usesSidebar && traitCollection.horizontalSizeClass == .regular
  }

  /// The view under `point` (in this controller's view) when it belongs to
  /// the native chrome, nil otherwise. Nil while the chrome is hidden, so it
  /// never takes a touch from Flutter.
  func hitTestBar(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard barVisible, let hit = view.hitTest(point, with: event) else { return nil }
    if usesSidebar { return sidebarHit(hit) }
    if hit.isDescendant(of: tabBar) { return hit }
    if bottomAccessory != nil, let host = accessoryHost(), hit.isDescendant(of: host) {
      return hit
    }
    return nil
  }

  // MARK: Driven by Dart

  func setTabs(_ newSpecs: [NativeTabSpec]) {
    if usesSidebar {
      // Compact width: iPadOS shows a tab bar of the top-level tabs.
      guard newSpecs != specs || !sidebarSections.isEmpty else { return }
      specs = newSpecs
      sidebarSections = []
      tabsById = [:]
      setTabs(newSpecs.map(makeTab), animated: false)
      if let selectedId { applySelection(selectedId) }
      return
    }

    guard newSpecs != specs else { return }
    specs = newSpecs

    var controllers = viewControllers ?? []
    if controllers.count > specs.count {
      controllers.removeLast(controllers.count - specs.count)
    }
    while controllers.count < specs.count {
      controllers.append(makeContent())
    }
    for (controller, spec) in zip(controllers, specs) {
      let item: UITabBarItem = controller.tabBarItem
      item.title = spec.title
      item.image = Self.symbol(named: spec.symbol)
      item.badgeValue = spec.badge
      item.isEnabled = spec.enabled
      item.accessibilityIdentifier = "native-tab-\(spec.id)"
    }
    setViewControllers(controllers, animated: false)
    // Replacing the controllers can move the selection; put it back.
    if let selectedId { applySelection(selectedId) }
  }

  /// Regular width on an iPad. The leading and trailing sections are
  /// top-level tabs; every other section is a sidebar-only group.
  func setSidebar(_ sections: [NativeSidebarSectionSpec]) {
    guard usesSidebar else { return }
    guard sections != sidebarSections || sidebarSections.isEmpty else { return }
    sidebarSections = sections
    specs = sections.flatMap(\.items)
    tabsById = [:]

    var built: [UITab] = []
    for section in sections {
      let children = section.items.map(makeTab)
      if section.id == "leading" || section.id == "trailing" {
        built.append(contentsOf: children)
        continue
      }
      let group = UITabGroup(
        title: section.title ?? "",
        image: nil,
        identifier: "section-\(section.id)",
        children: children
      ) { [weak self] _ in self?.makeContent() ?? PassThroughViewController() }
      group.preferredPlacement = .sidebarOnly
      group.allowsReordering = false
      built.append(group)
    }
    setTabs(built, animated: false)
    if let selectedId { applySelection(selectedId) }
  }

  /// Moves the selection without emitting `onTabSelected`.
  func select(_ id: String) {
    selectedId = id
    applySelection(id)
  }

  func setBarVisible(_ visible: Bool) {
    guard visible != barVisible else { return }
    barVisible = visible
    if usesSidebar {
      // Fading the whole view keeps the sidebar's own shown/hidden state,
      // which belongs to the user's toggle.
      UIView.animate(withDuration: 0.25) { self.view.alpha = visible ? 1 : 0 }
      applyAccessory()
      reportInsets()
      return
    }
    setTabBarHidden(!visible, animated: true)
    applyAccessory()
    // Showing: the selected tab's inset is still the hidden value here;
    // viewSafeAreaInsetsDidChange / viewDidLayoutSubviews report the real one.
    if !visible { reportInsets() }
  }

  /// Nil removes the accessory.
  func setAccessory(_ model: CastAccessoryModel?) {
    accessoryModel = model
    if let model { accessoryView.apply(model) }
    applyAccessory()
  }

  // MARK: UITabBarControllerDelegate

  func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelect viewController: UIViewController
  ) -> Bool {
    guard !usesSidebar,
          let index = viewControllers?.firstIndex(of: viewController),
          index < specs.count else { return false }
    let spec = specs[index]
    if spec.enabled { onTabSelected?(spec.id) }
    return false
  }

  func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelectTab tab: UITab
  ) -> Bool {
    // The iPhone answers through `shouldSelect viewController`.
    guard usesSidebar else { return true }
    if let spec = specs.first(where: { $0.id == tab.identifier }), spec.enabled {
      onTabSelected?(spec.id)
    }
    return false
  }

  // MARK: Helpers

  /// The named SF Symbol, or `circle` (logged) when the name does not exist.
  static func symbol(named name: String) -> UIImage? {
    if let image = UIImage(systemName: name) { return image }
    NSLog("[NativeTabBar] unknown SF Symbol %@, using circle", name)
    return UIImage(systemName: "circle")
  }

  private func makeContent() -> PassThroughViewController {
    let content = PassThroughViewController()
    content.onSafeAreaChange = { [weak self] in self?.reportInsets() }
    return content
  }

  private func makeTab(_ spec: NativeTabSpec) -> UITab {
    let tab = UITab(
      title: spec.title,
      image: Self.symbol(named: spec.symbol),
      identifier: spec.id
    ) { [weak self] _ in self?.makeContent() ?? PassThroughViewController() }
    tab.badgeValue = spec.badge
    tab.isEnabled = spec.enabled
    tab.allowsHiding = false
    tabsById[spec.id] = tab
    return tab
  }

  private func applySelection(_ id: String) {
    if usesSidebar {
      guard let tab = tabsById[id] else {
        NSLog("[NativeTabBar] select: unknown tab id %@", id)
        return
      }
      if selectedTab !== tab { selectedTab = tab }
      return
    }
    guard let index = specs.firstIndex(where: { $0.id == id }) else {
      NSLog("[NativeTabBar] select: unknown tab id %@", id)
      return
    }
    if selectedIndex != index { selectedIndex = index }
  }

  /// The accessory shows only while the bar does.
  private func applyAccessory() {
    let wanted: UITabAccessory? = (barVisible && accessoryModel != nil) ? accessory : nil
    guard bottomAccessory !== wanted else { return }
    setBottomAccessory(wanted, animated: true)
  }

  /// The selected tab's safe area already includes the bar, the accessory and
  /// the home indicator, which is exactly the inset Flutter has to clear. On
  /// an iPad the content's leading edge is where it starts in the root
  /// (iPadOS may move the frame or the safe area), and the top is the
  /// floating tab bar shown while the sidebar is hidden.
  private func reportInsets() {
    var insets: [Double] = [0, 0, 0]
    if barVisible, let content = (selectedTab?.viewController ?? selectedViewController)?.view,
       content.window != nil {
      let safe = content.safeAreaInsets
      if usesSidebar {
        let frame = content.convert(content.bounds, to: view)
        insets = [Double(safe.top), Double(frame.minX + safe.left), Double(safe.bottom)]
      } else {
        insets = [0, 0, Double(safe.bottom)]
      }
    }
    guard insets != lastReportedInsets else { return }
    lastReportedInsets = insets
    onInsetsChanged?(insets[0], insets[1], insets[2])
  }

  private func reportLayout() {
    guard usesSidebar else { return }
    let sidebar = isSidebarLayout
    guard sidebar != lastReportedLayout else { return }
    lastReportedLayout = sidebar
    onLayoutChanged?(sidebar)
    reportInsets()
  }

  /// A hit on the sidebar, the floating tab bar or their buttons. UIKit
  /// nests them in full-screen containers, which would claim every touch;
  /// those and the tab content are refused.
  private func sidebarHit(_ hit: UIView) -> UIView? {
    if hit is PassThroughView { return nil }
    if hit.bounds.width >= view.bounds.width, hit.bounds.height >= view.bounds.height {
      return nil
    }
    return hit
  }

  /// The accessory's outermost private wrapper (its glass capsule) that is
  /// still smaller than the screen, so a tap on the capsule's padding counts.
  /// UIKit also nests the accessory in full-screen containers; those stop the
  /// walk, or every touch would count as an accessory touch.
  private func accessoryHost() -> UIView? {
    var host: UIView = accessoryView
    while let parent = host.superview, parent !== view,
          parent.bounds.height < view.bounds.height {
      host = parent
    }
    return host
  }
}

/// A tab's content: transparent and never hit. The root routes touches by
/// `hitTestBar`, so this only keeps a stray content view from ever answering.
@available(iOS 26.0, *)
final class PassThroughViewController: UIViewController {
  var onSafeAreaChange: (() -> Void)?

  override func loadView() { view = PassThroughView() }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    onSafeAreaChange?()
  }

  // A sidebar that resizes the content moves its frame without touching the
  // safe area.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    onSafeAreaChange?()
  }
}

private final class PassThroughView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
#endif
