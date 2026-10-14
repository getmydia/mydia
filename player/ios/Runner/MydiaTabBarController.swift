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

/// The window root on iOS 26 iPhones: a real tab bar over the Flutter view.
///
/// Flutter draws every screen. The `FlutterViewController` is added once as a
/// child, pinned full screen beneath the tab content, and never re-parented:
/// moving it sends the app lifecycle `inactive`, which pauses playback and
/// raises the privacy blur. Each tab hosts an empty, touch-transparent
/// controller, so every touch outside the bar and the accessory reaches
/// Flutter.
///
/// Flutter's route decides the selection. A tap is reported through
/// `onTabSelected` and refused here; Dart navigates and answers with `select`.
@available(iOS 26.0, *)
final class MydiaTabBarController: UITabBarController, UITabBarControllerDelegate {
  let flutterViewController: FlutterViewController

  var onTabSelected: ((String) -> Void)?
  var onInsetsChanged: ((Double) -> Void)?
  var onAccessoryTapped: (() -> Void)?
  var onAccessoryPlayPause: (() -> Void)?

  private var specs: [NativeTabSpec] = []
  private var selectedId: String?
  private var barVisible = false
  private var accessoryModel: CastAccessoryModel?
  private var lastReportedInset: Double?

  private lazy var accessoryView: CastAccessoryView = {
    let view = CastAccessoryView()
    view.onTap = { [weak self] in self?.onAccessoryTapped?() }
    view.onPlayPause = { [weak self] in self?.onAccessoryPlayPause?() }
    return view
  }()

  private lazy var accessory = UITabAccessory(contentView: accessoryView)

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    overrideUserInterfaceStyle = .dark
    tabBarMinimizeBehavior = .never
    view.backgroundColor = .black

    addChild(flutterViewController)
    let flutterView: UIView = flutterViewController.view
    flutterView.frame = view.bounds
    flutterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.insertSubview(flutterView, at: 0)
    flutterViewController.didMove(toParent: self)

    // Hidden until Dart asks for it, so a launch that never reaches the shell
    // (login, startup errors) shows no empty bar.
    setTabBarHidden(true, animated: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    passTouchesThroughContentContainers()
    reportInsets()
  }

  // Flutter owns the status bar, the home indicator, orientation and edge
  // gestures (the immersive player changes all four). The root controller is
  // the one UIKit asks, so it forwards each to Flutter.
  override var childForStatusBarStyle: UIViewController? { flutterViewController }
  override var childForStatusBarHidden: UIViewController? { flutterViewController }
  override var childForHomeIndicatorAutoHidden: UIViewController? { flutterViewController }
  override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
    flutterViewController
  }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    flutterViewController.supportedInterfaceOrientations
  }
  override var shouldAutorotate: Bool { flutterViewController.shouldAutorotate }

  // MARK: Driven by Dart

  func setTabs(_ newSpecs: [NativeTabSpec]) {
    guard newSpecs != specs else { return }
    specs = newSpecs

    var controllers = viewControllers ?? []
    if controllers.count > specs.count {
      controllers.removeLast(controllers.count - specs.count)
    }
    while controllers.count < specs.count {
      let content = PassThroughViewController()
      content.onSafeAreaChange = { [weak self] in self?.reportInsets() }
      controllers.append(content)
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

  /// Moves the selection without emitting `onTabSelected`.
  func select(_ id: String) {
    selectedId = id
    applySelection(id)
  }

  func setBarVisible(_ visible: Bool) {
    guard visible != barVisible else { return }
    barVisible = visible
    setTabBarHidden(!visible, animated: true)
    applyAccessory()
    reportInsets()
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
    guard let index = viewControllers?.firstIndex(of: viewController),
          index < specs.count else { return false }
    let spec = specs[index]
    if spec.enabled { onTabSelected?(spec.id) }
    return false
  }

  // MARK: Helpers

  /// The named SF Symbol, or `circle` (logged) when the name does not exist.
  static func symbol(named name: String) -> UIImage? {
    if let image = UIImage(systemName: name) { return image }
    NSLog("[NativeTabBar] unknown SF Symbol %@, using circle", name)
    return UIImage(systemName: "circle")
  }

  private func applySelection(_ id: String) {
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
  /// the home indicator, which is exactly the inset Flutter has to clear.
  private func reportInsets() {
    let inset = barVisible
      ? Double(selectedViewController?.view.safeAreaInsets.bottom ?? 0)
      : 0
    guard inset != lastReportedInset else { return }
    lastReportedInset = inset
    onInsetsChanged?(inset)
  }

  /// UIKit wraps the selected tab's view in private container views that sit
  /// above the Flutter view, and a container whose subviews all miss claims
  /// the touch itself. Those containers are made non-interactive too,
  /// stopping at any that holds the tab bar or the accessory.
  private func passTouchesThroughContentContainers() {
    var node = selectedViewController?.view?.superview
    while let container = node,
          container !== view,
          !tabBar.isDescendant(of: container),
          !accessoryView.isDescendant(of: container) {
      container.isUserInteractionEnabled = false
      node = container.superview
    }
  }
}

/// A tab's content: transparent and never hit, so touches fall through to
/// the Flutter view underneath.
@available(iOS 26.0, *)
final class PassThroughViewController: UIViewController {
  var onSafeAreaChange: (() -> Void)?

  override func loadView() { view = PassThroughView() }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
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
