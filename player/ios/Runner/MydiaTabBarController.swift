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

/// A real tab bar over the Flutter view on iOS 26 iPhones.
///
/// Flutter draws every screen. This controller is a sibling above the
/// `FlutterViewController`, both children of `MydiaRootViewController`, and
/// never holds Flutter itself: `UITabBarController` owns its view's subviews
/// and drops any it did not add, which took the Flutter view out of the
/// window. Each tab hosts an empty, clear controller, and the root routes
/// every touch outside the bar and the accessory to Flutter (`hitTestBar`).
///
/// Flutter's route decides the selection. A tap is reported through
/// `onTabSelected` and refused here; Dart navigates and answers with `select`.
@available(iOS 26.0, *)
final class MydiaTabBarController: UITabBarController, UITabBarControllerDelegate {
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

  init() {
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
    // (login, startup errors) shows no empty bar.
    setTabBarHidden(true, animated: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    reportInsets()
  }

  /// The view under `point` (in this controller's view) when it belongs to
  /// the tab bar or the accessory, nil otherwise. Nil while the bar is
  /// hidden, so a hidden bar never takes a touch from Flutter.
  func hitTestBar(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard barVisible, let hit = view.hitTest(point, with: event) else { return nil }
    if hit.isDescendant(of: tabBar) { return hit }
    if bottomAccessory != nil, let host = accessoryHost(), hit.isDescendant(of: host) {
      return hit
    }
    return nil
  }

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
