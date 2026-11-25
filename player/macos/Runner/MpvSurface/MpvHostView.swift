import Cocoa
import QuartzCore

/// The `mydia/mpv-surface` platform view. mpv's mac video output adds its
/// own view inside this one, found through the `wid` the plugin passes it.
final class MpvHostView: NSView {
  /// The `mpv_handle` address whose video output lives in this view, set
  /// when `attach` arrives and cleared when a detach for it is requested.
  var attachedHandle: Int?

  /// Called with `attachedHandle` when the view leaves its window while
  /// still attached (hot restart, an error path that skipped `detach`).
  var onLeaveWindow: ((Int) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// The EDR state each `CAMetalLayer` under this view had when it was last
  /// committed from the main thread. Main only.
  private var committedEdr: [ObjectIdentifier: String] = [:]

  /// Re-commits, from the main thread, the EDR flag of every `CAMetalLayer`
  /// under this view whose EDR state changed since the last call. Main only.
  ///
  /// MoltenVK sets the layer's colorspace, EDR metadata and
  /// `wantsExtendedDynamicRangeContent` when mpv's VO thread creates the
  /// swapchain. That thread has no run loop, so Core Animation does not
  /// reliably commit the change to the window server: the layer reads back
  /// as a PQ EDR layer in-process, while macOS never raises the screen's
  /// headroom for it and PQ highlights stay clipped at SDR white. Setting
  /// the same values again is a no-op for Core Animation, so the flag goes
  /// off and on in two transactions here, which makes it send the layer's
  /// state. Measured on an M2 Pro XDR panel: the headroom stayed at 1.2
  /// without this in three runs out of three, and rose past 5 with it.
  func commitEdrState() {
    var seen: [ObjectIdentifier: String] = [:]
    for metal in Self.metalLayers(under: layer) {
      let id = ObjectIdentifier(metal)
      let state = Self.edrState(of: metal)
      seen[id] = state
      guard metal.wantsExtendedDynamicRangeContent, committedEdr[id] != state else { continue }
      CATransaction.begin()
      metal.wantsExtendedDynamicRangeContent = false
      CATransaction.commit()
      CATransaction.begin()
      metal.wantsExtendedDynamicRangeContent = true
      CATransaction.commit()
    }
    committedEdr = seen
  }

  private static func metalLayers(under root: CALayer?) -> [CAMetalLayer] {
    guard let root else { return [] }
    var found: [CAMetalLayer] = []
    var pending = [root]
    while let next = pending.popLast() {
      if let metal = next as? CAMetalLayer { found.append(metal) }
      pending.append(contentsOf: next.sublayers ?? [])
    }
    return found
  }

  private static func edrState(of metal: CAMetalLayer) -> String {
    let space = metal.colorspace?.name.map { $0 as String } ?? "none"
    let metadata = metal.edrMetadata.map { "\(ObjectIdentifier($0).hashValue)" } ?? "none"
    return "\(metal.wantsExtendedDynamicRangeContent) \(space) \(metadata)"
  }

  /// Where keyboard focus goes back to when this view or mpv's view inside
  /// it holds it: Flutter's view. Weak, since the plugin sets it once and
  /// the Flutter view outlives every host.
  weak var focusFallback: NSView?

  /// Never the target of a mouse event: clicks and drags over the video go
  /// to Flutter, which draws the player's gestures and controls over it.
  ///
  /// mpv's own view, which it adds inside this one, overrides `mouseDown`
  /// and accepts first responder. Without this, a click on the video went to
  /// mpv, so double-click to fullscreen did nothing, and the click made
  /// mpv's view the key view, so the arrow keys never reached Flutter again.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Whether this view or one inside it is the window's first responder.
  var holdsFocus: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  /// Gives keyboard focus back to Flutter if this view's subtree holds it.
  func returnFocus() {
    guard holdsFocus, let window, let target = focusFallback, target.window === window
    else { return }
    window.makeFirstResponder(target)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    // Leaving while holding focus would leave the window itself as first
    // responder, and Flutter would stop getting key events.
    if newWindow == nil { returnFocus() }
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil, let handle = attachedHandle else { return }
    attachedHandle = nil
    onLeaveWindow?(handle)
  }
}
