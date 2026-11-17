import Cocoa
import FlutterMacOS
import XCTest

@testable import Mydia_Player

/// Records every libmpv call the plugin makes, with the thread it came from.
final class FakeMpvApi: MpvApi {
  struct Call: Equatable {
    let op: String
    let name: String
    let value: String?
    let onMain: Bool
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var currentVo: [String?]
  var trackList: String?

  /// `currentVo` is consumed one entry per `current-vo` read; the last entry
  /// repeats once the list is down to one.
  init(trackList: String? = nil, currentVo: [String?] = [nil]) {
    self.trackList = trackList
    self.currentVo = currentVo
  }

  var calls: [Call] { lock.withLock { _calls } }
  var writes: [Call] { calls.filter { $0.op == "set" } }
  var writePairs: [String] { writes.map { "\($0.name)=\($0.value ?? "")" } }
  var currentVoReads: Int { calls.filter { $0.op == "get" && $0.name == "current-vo" }.count }

  func setOption(_ h: OpaquePointer, _ k: String, _ v: String) -> Int32 {
    lock.withLock { _calls.append(Call(op: "set", name: k, value: v, onMain: Thread.isMainThread)) }
    return 0
  }

  func getString(_ h: OpaquePointer, _ k: String) -> String? {
    lock.withLock {
      _calls.append(Call(op: "get", name: k, value: nil, onMain: Thread.isMainThread))
      switch k {
      case "track-list": return trackList
      case "current-vo":
        return currentVo.count > 1 ? currentVo.removeFirst() : currentVo.first ?? nil
      default: return nil
      }
    }
  }
}

/// A clock whose `sleep` advances time instead of blocking.
final class VirtualClock {
  private let lock = NSLock()
  private var t: TimeInterval = 0
  var now: TimeInterval { lock.withLock { t } }
  func sleep(_ d: TimeInterval) { lock.withLock { t += d } }
}

final class MpvSurfacePluginTests: XCTestCase {
  private let handle = 0x1234
  private let videoTracks = #"[{"id":1,"type":"video"},{"id":1,"type":"audio"}]"#
  private let audioOnly = #"[{"id":1,"type":"audio"}]"#

  private var logs: [String] = []

  private func makePlugin(
    api: FakeMpvApi, clock: VirtualClock = VirtualClock(),
    sleep: ((TimeInterval) -> Void)? = nil
  ) -> MpvSurfacePlugin {
    MpvSurfacePlugin(
      api: api,
      queue: DispatchQueue(label: "dev.mydia.mpv-surface.test"),
      now: { clock.now },
      sleep: sleep ?? { clock.sleep($0) },
      pollInterval: 0.05,
      log: { [weak self] line in DispatchQueue.main.async { self?.logs.append(line) } })
  }

  private func makeView(_ plugin: MpvSurfacePlugin, id: Int64 = 7) -> MpvHostView {
    plugin.create(withViewIdentifier: id, arguments: [:]) as! MpvHostView
  }

  /// Sends `method` through the plugin's channel handler and waits for the reply.
  @discardableResult
  private func call(
    _ plugin: MpvSurfacePlugin, _ method: String, _ args: [String: Any],
    timeout: TimeInterval = 5
  ) -> Any? {
    let done = expectation(description: method)
    var reply: Any?
    plugin.handle(FlutterMethodCall(methodName: method, arguments: args)) { value in
      XCTAssertTrue(Thread.isMainThread, "\(method) replied off the main thread")
      reply = value
      done.fulfill()
    }
    wait(for: [done], timeout: timeout)
    return reply
  }

  private func attachArgs(viewId: Int64 = 7, options: [[String]] = []) -> [String: Any] {
    ["handle": handle, "viewId": viewId, "options": options]
  }

  // MARK: attach

  func testAttachSetsWidFirstAndVidAutoLast() {
    let api = FakeMpvApi()
    let plugin = makePlugin(api: api)
    let view = makeView(plugin)
    let options = [["vo", "gpu-next"], ["gpu-api", "vulkan"], ["hwdec", "videotoolbox"]]

    let reply = call(plugin, "attach", attachArgs(options: options))

    XCTAssertNil(reply)
    let wid = String(Int(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
    XCTAssertEqual(
      api.writePairs,
      ["wid=\(wid)", "vo=gpu-next", "gpu-api=vulkan", "hwdec=videotoolbox", "vid=auto"])
    XCTAssertEqual(view.attachedHandle, handle)
  }

  func testAttachNeverCallsMpvOnMainThread() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil, "gpu-next"])
    let plugin = makePlugin(api: api)
    _ = makeView(plugin)

    call(plugin, "attach", attachArgs(options: [["vo", "gpu-next"]]))
    call(plugin, "setOption", ["handle": handle, "name": "panscan", "value": "1.0"])
    call(plugin, "awaitVideoOutput", ["handle": handle])
    call(plugin, "detach", ["handle": handle])

    XCTAssertFalse(api.calls.isEmpty)
    XCTAssertEqual(api.calls.filter(\.onMain), [])
  }

  func testAttachToUnknownViewIsAnError() {
    let api = FakeMpvApi()
    let plugin = makePlugin(api: api)

    let reply = call(plugin, "attach", attachArgs(viewId: 99))

    XCTAssertEqual((reply as? FlutterError)?.code, "no-view")
    XCTAssertEqual(api.calls, [])
  }

  // MARK: awaitVideoOutput

  func testNoVideoTrackStartsImmediately() {
    let api = FakeMpvApi(trackList: audioOnly, currentVo: [nil])
    let clock = VirtualClock()
    let plugin = makePlugin(api: api, clock: clock)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, true)
    XCTAssertEqual(api.currentVoReads, 0)
    XCTAssertEqual(clock.now, 0)
  }

  func testAwaitVideoOutputReportsTrueOnceVoAppears() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil, "", "gpu-next"])
    let plugin = makePlugin(api: api)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, true)
    XCTAssertEqual(api.currentVoReads, 3)
  }

  func testAwaitVideoOutputReportsFalseWhenVoNeverAppears() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil])
    let clock = VirtualClock()
    let plugin = makePlugin(api: api, clock: clock)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertGreaterThanOrEqual(clock.now, 2.0)
    XCTAssertLessThan(clock.now, 2.1)
  }

  // MARK: detach

  func testDetachWaitsForCurrentVoToClear() {
    let api = FakeMpvApi(currentVo: ["gpu-next", "gpu-next", "gpu-next", ""])
    let plugin = makePlugin(api: api)
    let done = expectation(description: "detach")
    var readsAtReply = -1

    plugin.handle(FlutterMethodCall(methodName: "detach", arguments: ["handle": handle])) { _ in
      readsAtReply = api.currentVoReads
      done.fulfill()
    }
    wait(for: [done], timeout: 5)

    XCTAssertEqual(api.writePairs, ["vid=no"])
    XCTAssertEqual(readsAtReply, 4)
    XCTAssertFalse(logs.contains { $0.contains("timed out") })
  }

  func testDetachGivesUpAfterThreeSeconds() {
    let api = FakeMpvApi(currentVo: ["gpu-next"])
    let clock = VirtualClock()
    let plugin = makePlugin(api: api, clock: clock)

    call(plugin, "detach", ["handle": handle])
    // The log line is delivered with a main-queue hop of its own.
    let logged = expectation(description: "timeout logged")
    DispatchQueue.main.async { logged.fulfill() }
    wait(for: [logged], timeout: 1)

    XCTAssertGreaterThanOrEqual(clock.now, 3.0)
    XCTAssertLessThan(clock.now, 3.1)
    XCTAssertTrue(logs.contains { $0.contains("timed out") }, "\(logs)")
  }

  func testDetachQueuedBehindAttachWaitsForIt() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil, nil, "gpu-next", ""])
    let gate = DispatchSemaphore(value: 0)
    let clock = VirtualClock()
    let firstSleep = expectation(description: "await is polling")
    var slept = false
    let plugin = makePlugin(api: api, clock: clock) { d in
      if !slept {
        slept = true
        firstSleep.fulfill()
        gate.wait()
      }
      clock.sleep(d)
    }
    _ = makeView(plugin)

    var order: [String] = []
    let attached = expectation(description: "attach")
    let awaited = expectation(description: "await")
    let detached = expectation(description: "detach")
    plugin.handle(FlutterMethodCall(methodName: "attach", arguments: attachArgs())) { _ in
      order.append("attach")
      attached.fulfill()
    }
    plugin.handle(FlutterMethodCall(methodName: "awaitVideoOutput", arguments: ["handle": handle])) {
      _ in
      order.append("await")
      awaited.fulfill()
    }
    wait(for: [firstSleep], timeout: 5)
    plugin.handle(FlutterMethodCall(methodName: "detach", arguments: ["handle": handle])) { _ in
      order.append("detach")
      detached.fulfill()
    }

    // Still polling: detach must not have reached mpv yet.
    XCTAssertFalse(api.writePairs.contains("vid=no"))
    gate.signal()
    wait(for: [attached, awaited, detached], timeout: 5)

    XCTAssertEqual(order, ["attach", "await", "detach"])
    let pairs = api.writePairs
    XCTAssertEqual(pairs.last, "vid=no")
    XCTAssertEqual(pairs.dropLast().last, "vid=auto")
    XCTAssertTrue(pairs.first?.hasPrefix("wid=") ?? false)
  }

  // MARK: host view

  func testViewLeavingWindowDetaches() {
    let api = FakeMpvApi()
    let plugin = makePlugin(api: api)
    let view = makeView(plugin)
    call(plugin, "attach", attachArgs())

    view.viewWillMove(toWindow: nil)
    let drained = expectation(description: "drain")
    plugin.queueForTesting.async { DispatchQueue.main.async { drained.fulfill() } }
    wait(for: [drained], timeout: 5)

    XCTAssertEqual(api.writePairs.last, "vid=no")
    XCTAssertNil(view.attachedHandle)

    // A second removal does not detach twice.
    view.viewWillMove(toWindow: nil)
    let drainedAgain = expectation(description: "drain again")
    plugin.queueForTesting.async { DispatchQueue.main.async { drainedAgain.fulfill() } }
    wait(for: [drainedAgain], timeout: 5)
    XCTAssertEqual(api.writePairs.filter { $0 == "vid=no" }.count, 1)
  }

  func testViewDoesNotDetachAgainAfterExplicitDetach() {
    let api = FakeMpvApi()
    let plugin = makePlugin(api: api)
    let view = makeView(plugin)
    call(plugin, "attach", attachArgs())
    call(plugin, "detach", ["handle": handle])

    view.viewWillMove(toWindow: nil)
    let drained = expectation(description: "drain")
    plugin.queueForTesting.async { DispatchQueue.main.async { drained.fulfill() } }
    wait(for: [drained], timeout: 5)

    XCTAssertEqual(api.writePairs.filter { $0 == "vid=no" }.count, 1)
  }

  func testHostViewIsLayerBackedAndBlack() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    XCTAssertTrue(view.wantsLayer)
    XCTAssertEqual(view.layer?.backgroundColor, NSColor.black.cgColor)
  }
}
