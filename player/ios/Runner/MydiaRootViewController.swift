#if compiler(>=6.2)
import Flutter
import UIKit

/// The window root on iOS 26 iPhones: a plain container holding the Flutter
/// view and, above it, the native tab bar.
///
/// The `FlutterViewController` is added once, full screen at the bottom, and
/// never moved: re-parenting it sends the app lifecycle `inactive`, which
/// pauses playback and raises the privacy blur. A plain container forwards
/// appearance calls to it unchanged, so Flutter keeps rendering through tab
/// changes. `MydiaTabBarController` sits on top, clear, and only ever takes
/// touches on the bar and the accessory (`RootTouchView`).
@available(iOS 26.0, *)
final class MydiaRootViewController: UIViewController {
  let flutterViewController: FlutterViewController
  let tabs = MydiaTabBarController()

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func loadView() {
    let root = RootTouchView()
    root.backgroundColor = .black
    root.route = { [weak self] point, event in self?.route(point, with: event) }
    view = root
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    embed(flutterViewController)
    embed(tabs)
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

  private func embed(_ child: UIViewController) {
    addChild(child)
    let childView: UIView = child.view
    childView.frame = view.bounds
    childView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(childView)
    child.didMove(toParent: self)
  }

  /// The bar or the accessory when the touch lands on one; Flutter otherwise.
  private func route(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let tabsView: UIView = tabs.view
    if let hit = tabs.hitTestBar(view.convert(point, to: tabsView), with: event) {
      return hit
    }
    let flutterView: UIView = flutterViewController.view
    return flutterView.hitTest(view.convert(point, to: flutterView), with: event)
  }
}

/// Hands every hit test to the root's `route`. UIKit's tab containers cover
/// the whole screen and would otherwise claim touches meant for Flutter.
private final class RootTouchView: UIView {
  var route: ((CGPoint, UIEvent?) -> UIView?)?

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event)
    else { return nil }
    return route?(point, event)
  }
}
#endif
