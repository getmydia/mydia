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

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil, let handle = attachedHandle else { return }
    attachedHandle = nil
    onLeaveWindow?(handle)
  }
}
