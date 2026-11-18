import Foundation

/// The slice of libmpv `MpvSurfacePlugin` uses, so tests can swap in a fake.
///
/// Both calls go through mpv's property API: media_kit has already run
/// `mpv_initialize` by the time the plugin sees a handle, and options set
/// after that must be set as properties.
protocol MpvApi: AnyObject {
  /// `mpv_set_property_string`. Returns mpv's error code, 0 on success.
  func setOption(_ h: OpaquePointer, _ k: String, _ v: String) -> Int32
  /// `mpv_get_property_string`, or nil when mpv has no value for `k`.
  func getString(_ h: OpaquePointer, _ k: String) -> String?
}

/// libmpv as loaded into the process by media_kit's `Mpv.framework`.
///
/// The symbols are resolved at runtime rather than linked, so the Runner
/// target needs no link settings for a framework a pod already embeds. If
/// they cannot be found, every call fails with `MPV_ERROR_NOT_IMPLEMENTED`
/// and the failure is logged once.
final class LiveMpvApi: MpvApi {
  static let shared = LiveMpvApi()

  /// `MPV_ERROR_NOT_IMPLEMENTED` in client.h.
  static let unavailable: Int32 = -19

  private typealias SetPropertyString = @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
  ) -> Int32
  private typealias GetPropertyString = @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?
  ) -> UnsafeMutablePointer<CChar>?
  private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void

  private struct Symbols {
    let set: SetPropertyString
    let get: GetPropertyString
    let free: Free
  }

  private let symbols: Symbols?
  private let lock = NSLock()
  private var loggedMissing = false

  private init() {
    // RTLD_DEFAULT: search every image already loaded into the process.
    let all = UnsafeMutableRawPointer(bitPattern: -2)
    if let set = dlsym(all, "mpv_set_property_string"),
      let get = dlsym(all, "mpv_get_property_string"),
      let free = dlsym(all, "mpv_free")
    {
      symbols = Symbols(
        set: unsafeBitCast(set, to: SetPropertyString.self),
        get: unsafeBitCast(get, to: GetPropertyString.self),
        free: unsafeBitCast(free, to: Free.self))
    } else {
      symbols = nil
    }
  }

  func setOption(_ h: OpaquePointer, _ k: String, _ v: String) -> Int32 {
    guard let symbols = resolved() else { return Self.unavailable }
    return symbols.set(h, k, v)
  }

  func getString(_ h: OpaquePointer, _ k: String) -> String? {
    guard let symbols = resolved(), let raw = symbols.get(h, k) else { return nil }
    defer { symbols.free(raw) }
    return String(cString: raw)
  }

  private func resolved() -> Symbols? {
    if let symbols { return symbols }
    lock.withLock {
      if !loggedMissing {
        loggedMissing = true
        NSLog("MpvSurface: libmpv symbols not found in the process; mpv calls are no-ops")
      }
    }
    return nil
  }
}
