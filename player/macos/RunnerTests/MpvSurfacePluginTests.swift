import Cocoa
import FlutterMacOS
import QuartzCore
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
  private var _trackList: String?
  private var _vid: String?
  var trackList: String? {
    get { lock.withLock { _trackList } }
    set { lock.withLock { _trackList = newValue } }
  }
  /// What `vid` reads; nil reads as unset.
  var vid: String? {
    get { lock.withLock { _vid } }
    set { lock.withLock { _vid = newValue } }
  }

  /// `currentVo` is consumed one entry per `current-vo` read; the last entry
  /// repeats once the list is down to one.
  init(trackList: String? = nil, currentVo: [String?] = [nil]) {
    self._trackList = trackList
    self.currentVo = currentVo
  }

  var calls: [Call] { lock.withLock { _calls } }
  var writes: [Call] { calls.filter { $0.op == "set" } }
  var writePairs: [String] { writes.map { "\($0.name)=\($0.value ?? "")" } }
  var currentVoReads: Int { calls.filter { $0.op == "get" && $0.name == "current-vo" }.count }

  private var _refused: Set<String> = []
  /// Option names whose writes fail, as mpv does for one it rejects.
  var refused: Set<String> {
    get { lock.withLock { _refused } }
    set { lock.withLock { _refused = newValue } }
  }

  func setOption(_ h: OpaquePointer, _ k: String, _ v: String) -> Int32 {
    lock.withLock { () -> Int32 in
      _calls.append(Call(op: "set", name: k, value: v, onMain: Thread.isMainThread))
      return _refused.contains(k) ? -1 : 0
    }
  }

  func getString(_ h: OpaquePointer, _ k: String) -> String? {
    lock.withLock {
      _calls.append(Call(op: "get", name: k, value: nil, onMain: Thread.isMainThread))
      switch k {
      case "track-list": return _trackList
      case "vid": return _vid
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
  private let videoTracks =
    #"[{"id":1,"type":"video","selected":true},{"id":1,"type":"audio","selected":true}]"#
  /// What mpv leaves after it rejects the video output: the track is still
  /// listed, but deselected.
  private let videoDeselected =
    #"[{"id":1,"type":"video","selected":false},{"id":1,"type":"audio","selected":true}]"#
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
    // The plugin holds host views weakly: the test keeps this one alive.
    let view = makeView(plugin)

    withExtendedLifetime(view) {
      XCTAssertNil(call(plugin, "attach", attachArgs(options: [["vo", "gpu-next"]])))
      call(plugin, "setOption", ["handle": handle, "name": "panscan", "value": "1.0"])
      call(plugin, "awaitVideoOutput", ["handle": handle])
      call(plugin, "detach", ["handle": handle])
    }

    XCTAssertFalse(api.calls.isEmpty)
    XCTAssertEqual(api.calls.filter(\.onMain), [])
  }

  func testAttachFailsWhenMpvRefusesWid() {
    let api = FakeMpvApi()
    api.refused = ["wid"]
    let plugin = makePlugin(api: api)
    let view = makeView(plugin)

    let reply = withExtendedLifetime(view) {
      call(plugin, "attach", attachArgs(options: [["vo", "gpu-next"]]))
    }

    XCTAssertEqual((reply as? FlutterError)?.code, "attach-failed")
  }

  func testAttachStillSucceedsWhenAnOptionIsRefused() {
    let api = FakeMpvApi()
    api.refused = ["dither"]
    let plugin = makePlugin(api: api)
    let view = makeView(plugin)

    let reply = withExtendedLifetime(view) {
      call(plugin, "attach", attachArgs(options: [["dither", "auto"]]))
    }

    XCTAssertNil(reply)
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
    XCTAssertEqual(reply?["failed"] as? Bool, false)
    XCTAssertEqual(api.currentVoReads, 0)
    XCTAssertEqual(clock.now, 0)
  }

  func testTrackListStillEmptyAtTheDeadlineTimesOut() {
    let api = FakeMpvApi(trackList: "[]", currentVo: [nil])
    let clock = VirtualClock()
    let plugin = makePlugin(api: api, clock: clock)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertEqual(reply?["failed"] as? Bool, false)
    XCTAssertGreaterThanOrEqual(clock.now, 2.0)
  }

  func testUnreadableTrackListTimesOut() {
    let api = FakeMpvApi(trackList: nil, currentVo: [nil])
    let plugin = makePlugin(api: api)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertEqual(reply?["failed"] as? Bool, false)
  }

  func testVideoTrackListedAfterTheCheckStartsIsStillChecked() {
    let api = FakeMpvApi(trackList: "[]", currentVo: [nil])
    let clock = VirtualClock()
    // mpv lists the tracks after the first poll, then rejects the output.
    let plugin = makePlugin(api: api, clock: clock) { d in
      clock.sleep(d)
      api.trackList = self.videoDeselected
    }

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertEqual(reply?["failed"] as? Bool, true)
  }

  func testAwaitVideoOutputReportsTrueOnceVoAppears() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil, "", "gpu-next"])
    let plugin = makePlugin(api: api)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, true)
    XCTAssertEqual(reply?["failed"] as? Bool, false)
    XCTAssertEqual(api.currentVoReads, 3)
  }

  func testAwaitVideoOutputTimesOutWithoutFailingWhileTrackStaysSelected() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil])
    let clock = VirtualClock()
    let plugin = makePlugin(api: api, clock: clock)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertEqual(reply?["failed"] as? Bool, false)
    XCTAssertGreaterThanOrEqual(clock.now, 2.0)
    XCTAssertLessThan(clock.now, 2.1)
  }

  func testAwaitVideoOutputFailsOnceMpvDeselectsTheVideoTrack() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil])
    let clock = VirtualClock()
    // The track is selected for the first poll, then mpv rejects the output.
    let plugin = makePlugin(api: api, clock: clock) { d in
      clock.sleep(d)
      api.trackList = self.videoDeselected
    }

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertEqual(reply?["failed"] as? Bool, true)
    XCTAssertLessThan(clock.now, 0.1)
  }

  func testAwaitVideoOutputFailsWhenVidReadsNo() {
    let api = FakeMpvApi(trackList: videoTracks, currentVo: [nil])
    api.vid = "no"
    let clock = VirtualClock()
    let plugin = makePlugin(api: api, clock: clock)

    let reply = call(plugin, "awaitVideoOutput", ["handle": handle]) as? [String: Any]

    XCTAssertEqual(reply?["started"] as? Bool, false)
    XCTAssertEqual(reply?["failed"] as? Bool, true)
    XCTAssertEqual(clock.now, 0)
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

  func testHostViewStaysRetainedWhenDetachTimesOut() {
    let api = FakeMpvApi(currentVo: ["gpu-next"])
    let plugin = makePlugin(api: api)

    weak var weakView: MpvHostView?
    autoreleasepool {
      let view = makeView(plugin)
      weakView = view
      XCTAssertNil(call(plugin, "attach", attachArgs()))
      call(plugin, "detach", ["handle": handle])
    }

    XCTAssertNotNil(weakView, "host view freed while mpv may still draw into it")
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
    let view = makeView(plugin)

    var order: [String] = []
    let attached = expectation(description: "attach")
    let awaited = expectation(description: "await")
    let detached = expectation(description: "detach")
    plugin.handle(FlutterMethodCall(methodName: "attach", arguments: attachArgs())) { reply in
      XCTAssertNil(reply, "attach failed")
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
    withExtendedLifetime(view) {}
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

  func testStaleViewLeavingWindowDoesNotDetachNewerAttachment() {
    let api = FakeMpvApi()
    let plugin = makePlugin(api: api)
    let old = makeView(plugin, id: 7)
    let new = makeView(plugin, id: 8)
    call(plugin, "attach", attachArgs(viewId: 7))
    call(plugin, "attach", attachArgs(viewId: 8))

    old.viewWillMove(toWindow: nil)
    let drained = expectation(description: "drain")
    plugin.queueForTesting.async { DispatchQueue.main.async { drained.fulfill() } }
    wait(for: [drained], timeout: 5)

    XCTAssertFalse(api.writePairs.contains("vid=no"))
    XCTAssertNil(old.attachedHandle)
    XCTAssertEqual(new.attachedHandle, handle)
  }

  /// Sends a detach whose `current-vo` poll is held at its first sleep, drops
  /// the test's own reference to the host view, and checks the plugin keeps
  /// it alive until the detach completes.
  private func assertViewRetainedUntilDetachCompletes(
    viaLeaveWindow: Bool, file: StaticString = #filePath, line: UInt = #line
  ) {
    let api = FakeMpvApi(currentVo: ["gpu-next", ""])
    let gate = DispatchSemaphore(value: 0)
    let clock = VirtualClock()
    let polling = expectation(description: "detach is polling")
    var slept = false
    let plugin = makePlugin(api: api, clock: clock) { d in
      if !slept {
        slept = true
        polling.fulfill()
        gate.wait()
      }
      clock.sleep(d)
    }

    weak var weakView: MpvHostView?
    autoreleasepool {
      var view: MpvHostView? = makeView(plugin)
      weakView = view
      call(plugin, "attach", attachArgs())
      if viaLeaveWindow {
        view?.viewWillMove(toWindow: nil)
      } else {
        plugin.handle(FlutterMethodCall(methodName: "detach", arguments: ["handle": handle])) {
          _ in
        }
      }
      view = nil
    }
    wait(for: [polling], timeout: 5)
    XCTAssertNotNil(weakView, "host view freed while its detach was pending", file: file, line: line)

    gate.signal()
    let drained = expectation(description: "drain")
    plugin.queueForTesting.async { DispatchQueue.main.async { drained.fulfill() } }
    wait(for: [drained], timeout: 5)
    XCTAssertEqual(api.writePairs.last, "vid=no", file: file, line: line)
    XCTAssertNil(weakView, "host view still retained after its detach", file: file, line: line)
  }

  func testHostViewRetainedUntilExplicitDetachCompletes() {
    assertViewRetainedUntilDetachCompletes(viaLeaveWindow: false)
  }

  func testHostViewRetainedUntilLeaveWindowDetachCompletes() {
    assertViewRetainedUntilDetachCompletes(viaLeaveWindow: true)
  }

  // MARK: display headroom

  /// A timer the test fires by hand.
  final class FakeTimer {
    var interval: TimeInterval?
    var tick: (() -> Void)?
    var starts = 0
    var stops = 0
    var running: Bool { tick != nil }

    func schedule(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void {
      starts += 1
      self.interval = interval
      self.tick = tick
      return { [weak self] in
        self?.stops += 1
        self?.tick = nil
      }
    }

    func fire() { tick?() }
  }

  private struct DisplayHarness {
    let plugin: MpvSurfacePlugin
    let timer: FakeTimer
    let info: () -> MpvSurfacePlugin.DisplayInfo
    let setInfo: (MpvSurfacePlugin.DisplayInfo) -> Void
    let events: () -> [[String: Any]]
  }

  private func makeDisplayHarness() -> DisplayHarness {
    let timer = FakeTimer()
    var info = MpvSurfacePlugin.DisplayInfo(
      edrHeadroom: 1.2, potentialHeadroom: 16, screenName: "Built-in Display")
    var events: [[String: Any]] = []
    let plugin = MpvSurfacePlugin(
      api: FakeMpvApi(),
      queue: DispatchQueue(label: "dev.mydia.mpv-surface.test"),
      now: { 0 }, sleep: { _ in }, pollInterval: 0.05, log: { _ in },
      displayInfo: { info },
      scheduleTimer: timer.schedule)
    _ = plugin.onListen(withArguments: nil) { event in
      if let event = event as? [String: Any] { events.append(event) }
    }
    return DisplayHarness(
      plugin: plugin, timer: timer, info: { info }, setInfo: { info = $0 },
      events: { events })
  }

  func testListenEmitsCurrentDisplayAndNoTimerRunsWithoutAttachment() {
    let h = makeDisplayHarness()

    XCTAssertEqual(h.events().count, 1)
    XCTAssertEqual(h.events().first?["edrHeadroom"] as? Double, 1.2)
    XCTAssertEqual(h.events().first?["screenName"] as? String, "Built-in Display")
    XCTAssertFalse(h.timer.running)
  }

  func testRefreshTimerEmitsOnlyWhenHeadroomOrScreenChanges() {
    let h = makeDisplayHarness()
    let view = makeView(h.plugin)
    defer { withExtendedLifetime(view) {} }
    XCTAssertNil(call(h.plugin, "attach", attachArgs()))
    XCTAssertTrue(h.timer.running)
    XCTAssertEqual(h.timer.interval, 1)

    h.timer.fire()
    XCTAssertEqual(h.events().count, 1, "unchanged headroom emitted")

    var info = h.info()
    info.edrHeadroom = 1.205
    h.setInfo(info)
    h.timer.fire()
    XCTAssertEqual(h.events().count, 1, "a move within tolerance emitted")

    info.edrHeadroom = 16
    h.setInfo(info)
    h.timer.fire()
    XCTAssertEqual(h.events().count, 2)
    XCTAssertEqual(h.events().last?["edrHeadroom"] as? Double, 16)

    h.timer.fire()
    XCTAssertEqual(h.events().count, 2, "the same new value emitted twice")

    info.screenName = "External Display"
    h.setInfo(info)
    h.timer.fire()
    XCTAssertEqual(h.events().count, 3)
    XCTAssertEqual(h.events().last?["screenName"] as? String, "External Display")
  }

  func testRefreshTimerStopsAfterLastDetach() {
    let h = makeDisplayHarness()
    let first = makeView(h.plugin, id: 7)
    let second = makeView(h.plugin, id: 8)
    defer { withExtendedLifetime(second) {} }
    XCTAssertNil(call(h.plugin, "attach", ["handle": 0x1000, "viewId": 7, "options": []]))
    XCTAssertNil(call(h.plugin, "attach", ["handle": 0x2000, "viewId": 8, "options": []]))
    XCTAssertEqual(h.timer.starts, 1)

    first.viewWillMove(toWindow: nil)
    XCTAssertTrue(h.timer.running, "stopped while a view was still attached")

    call(h.plugin, "detach", ["handle": 0x2000])
    XCTAssertFalse(h.timer.running)
    XCTAssertEqual(h.timer.stops, 1)

    // Reattaching starts it again.
    XCTAssertNil(call(h.plugin, "attach", ["handle": 0x2000, "viewId": 8, "options": []]))
    XCTAssertTrue(h.timer.running)
    XCTAssertEqual(h.timer.starts, 2)
  }

  /// Records every write to `wantsExtendedDynamicRangeContent`.
  private final class RecordingMetalLayer: CAMetalLayer {
    var edrWrites: [Bool] = []
    override var wantsExtendedDynamicRangeContent: Bool {
      didSet { edrWrites.append(wantsExtendedDynamicRangeContent) }
    }
  }

  func testEdrStateIsRecommittedOnMainOncePerChange() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    let metal = RecordingMetalLayer()
    view.layer?.addSublayer(metal)
    // What MoltenVK does on the VO thread for a PQ swapchain.
    let set = expectation(description: "set off main")
    DispatchQueue.global().async {
      metal.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
      metal.wantsExtendedDynamicRangeContent = true
      set.fulfill()
    }
    wait(for: [set], timeout: 2)
    metal.edrWrites = []

    view.commitEdrState()
    XCTAssertEqual(metal.edrWrites, [false, true], "not toggled to force a commit")
    XCTAssertTrue(metal.wantsExtendedDynamicRangeContent)

    view.commitEdrState()
    XCTAssertEqual(metal.edrWrites, [false, true], "an unchanged state was toggled again")

    // A new swapchain (HLG) is a new state.
    metal.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
    view.commitEdrState()
    XCTAssertEqual(metal.edrWrites, [false, true, false, true])
  }

  func testEdrStateLeavesAnSdrLayerAlone() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    let metal = RecordingMetalLayer()
    metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    view.layer?.addSublayer(metal)

    view.commitEdrState()
    XCTAssertEqual(metal.edrWrites, [])
  }

  func testHostViewIsLayerBackedAndBlack() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    XCTAssertTrue(view.wantsLayer)
    XCTAssertEqual(view.layer?.backgroundColor, NSColor.black.cgColor)
  }

  /// Stands in for mpv's own view: it takes clicks and keyboard focus.
  private final class GreedyView: NSView {
    override var acceptsFirstResponder: Bool { true }
  }

  private func makeWindow(holding views: NSView...) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    for view in views {
      view.frame = window.contentView?.bounds ?? .zero
      window.contentView?.addSubview(view)
    }
    return window
  }

  func testHostViewNeverTakesAClickEvenOverMpvsView() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    let mpv = GreedyView(frame: view.bounds)
    view.addSubview(mpv)

    XCTAssertNil(view.hitTest(NSPoint(x: 50, y: 50)))
  }

  func testPluginHandsHostViewsTheFlutterViewForFocus() {
    let plugin = makePlugin(api: FakeMpvApi())
    let flutter = NSView()
    plugin.focusFallback = flutter

    XCTAssertTrue(makeView(plugin).focusFallback === flutter)
  }

  func testFocusInsideTheHostReturnsToFlutterWhenItLeavesTheWindow() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    let mpv = GreedyView()
    view.addSubview(mpv)
    let flutter = GreedyView()
    view.focusFallback = flutter
    let window = makeWindow(holding: flutter, view)
    defer { window.close() }

    XCTAssertTrue(window.makeFirstResponder(mpv))
    XCTAssertTrue(view.holdsFocus)

    view.removeFromSuperview()

    XCTAssertTrue(window.firstResponder === flutter, "focus was left on the window")
  }

  func testFocusElsewhereIsLeftAloneWhenTheHostLeaves() {
    let view = makeView(makePlugin(api: FakeMpvApi()))
    let flutter = GreedyView()
    let other = GreedyView()
    view.focusFallback = flutter
    let window = makeWindow(holding: flutter, other, view)
    defer { window.close() }

    XCTAssertTrue(window.makeFirstResponder(other))
    view.removeFromSuperview()

    XCTAssertTrue(window.firstResponder === other)
  }
}
