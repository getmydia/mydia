import Cocoa

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

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil, let handle = attachedHandle else { return }
    attachedHandle = nil
    onLeaveWindow?(handle)
  }
}
