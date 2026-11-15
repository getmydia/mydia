import CloudKit
import Flutter
import XCTest

@testable import Runner

/// The pure helpers of `CloudKitPlugin`; nothing here reaches iCloud.
class CloudKitPluginTests: XCTestCase {

  func testRecordToMapCarriesAllFields() {
    let record = CloudKitPlugin.makeRecord(
      slotId: "a1b2c3d4e5f60001", deviceName: "Living Room", platform: "ios", size: 42,
      updatedAtMs: 1_700_000_000_123, asset: nil)
    XCTAssertEqual(record.recordType, "Slot")
    XCTAssertEqual(record.recordID.recordName, "slot-a1b2c3d4e5f60001")
    XCTAssertEqual(record.recordID.zoneID.zoneName, "Backup")

    let map = CloudKitPlugin.recordToMap(record, tag: "t7")
    XCTAssertEqual(map?["slotId"] as? String, "a1b2c3d4e5f60001")
    XCTAssertEqual(map?["deviceName"] as? String, "Living Room")
    XCTAssertEqual(map?["platform"] as? String, "ios")
    XCTAssertEqual(map?["updatedAt"] as? Int64, 1_700_000_000_123)
    XCTAssertEqual(map?["size"] as? Int64, 42)
    XCTAssertEqual(map?["tag"] as? String, "t7")
  }

  func testRecordToMapNeedsATag() {
    let record = CloudKitPlugin.makeRecord(
      slotId: "a1b2c3d4e5f60001", deviceName: "Den", platform: "macos", size: 1,
      updatedAtMs: 1, asset: nil)
    // A record never saved has no change tag, so no version to list.
    XCTAssertNil(CloudKitPlugin.recordToMap(record))
  }

  func testSlotIdFromRecordName() {
    XCTAssertEqual(CloudKitPlugin.slotId(fromRecordName: "slot-abc"), "abc")
    XCTAssertNil(CloudKitPlugin.slotId(fromRecordName: "slot-"))
    XCTAssertNil(CloudKitPlugin.slotId(fromRecordName: "other"))
  }

  func testErrorCodeMapping() {
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.notAuthenticated)), "notAuthenticated")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.quotaExceeded)), "quotaExceeded")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.changeTokenExpired)), "changeTokenExpired")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.zoneNotFound)), "zoneNotFound")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.userDeletedZone)), "zoneNotFound")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.networkUnavailable)), "network")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.networkFailure)), "network")
    XCTAssertEqual(
      CloudKitPlugin.errorCode(CKError(.accountTemporarilyUnavailable)), "unavailable")
    XCTAssertEqual(CloudKitPlugin.errorCode(CKError(.internalError)), "other")
    XCTAssertEqual(CloudKitPlugin.errorCode(URLError(.notConnectedToInternet)), "network")

    let partial = CKError(
      .partialFailure,
      userInfo: [CKPartialErrorsByItemIDKey: ["slot-a": CKError(.quotaExceeded)]])
    XCTAssertEqual(CloudKitPlugin.errorCode(partial), "quotaExceeded")
  }

  func testRateLimitCarriesRetryAfter() {
    let limited = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 2.5])
    let error = CloudKitPlugin.flutterError(limited)
    XCTAssertEqual(error.code, "network")
    XCTAssertEqual((error.details as? [String: Any])?["retryAfterMs"] as? Int, 2500)
  }

  func testUnknownItemIsAlreadyGone() {
    XCTAssertTrue(CloudKitPlugin.isAlreadyGone(CKError(.unknownItem)))
    XCTAssertTrue(CloudKitPlugin.isAlreadyGone(CKError(.zoneNotFound)))
    XCTAssertFalse(CloudKitPlugin.isAlreadyGone(CKError(.networkFailure)))
  }

  func testEnabledOnlyByYes() {
    XCTAssertTrue(CloudKitPlugin.isEnabledValue("YES"))
    XCTAssertFalse(CloudKitPlugin.isEnabledValue("NO"))
    // The entitlements exist only for `YES`, so `yes` must not enable.
    XCTAssertFalse(CloudKitPlugin.isEnabledValue("yes"))
    XCTAssertFalse(CloudKitPlugin.isEnabledValue("Yes"))
    XCTAssertFalse(CloudKitPlugin.isEnabledValue(""))
    XCTAssertFalse(CloudKitPlugin.isEnabledValue(nil))
    // An unexpanded build setting is off, not on.
    XCTAssertFalse(CloudKitPlugin.isEnabledValue("$(MYDIA_CLOUDKIT)"))
  }

  func testDisabledBuildAnswersWithoutCloudKit() {
    XCTAssertNil(CloudKitPlugin.disabledAnswer(method: "fetchChanges", enabled: true))
    XCTAssertEqual(CloudKitPlugin.disabledAnswer(method: "isEnabled", enabled: false) as? Bool, false)
    XCTAssertEqual(
      (CloudKitPlugin.disabledAnswer(method: "accountStatus", enabled: false)
        as? [String: String])?["status"],
      "disabled")
    for method in ["fetchChanges", "fetchPayload", "save", "delete", "subscribe"] {
      XCTAssertEqual(
        (CloudKitPlugin.disabledAnswer(method: method, enabled: false) as? FlutterError)?.code,
        "unavailable", method)
    }
    XCTAssertTrue(
      CloudKitPlugin.disabledAnswer(method: "nope", enabled: false) as AnyObject
        === FlutterMethodNotImplemented as AnyObject)
  }

  func testStatusNames() {
    XCTAssertEqual(CloudKitPlugin.statusName(.available), "available")
    XCTAssertEqual(CloudKitPlugin.statusName(.noAccount), "noAccount")
    XCTAssertEqual(CloudKitPlugin.statusName(.restricted), "restricted")
    XCTAssertEqual(CloudKitPlugin.statusName(.temporarilyUnavailable), "temporarilyUnavailable")
    XCTAssertEqual(CloudKitPlugin.statusName(.couldNotDetermine), "temporarilyUnavailable")
  }

  /// A `CKServerChangeToken` has no public initializer, so the round trip
  /// runs the same secure-coding archive over another CloudKit type, and
  /// checks that the token reader refuses anything else.
  func testTokenArchiveRoundTrip() throws {
    let zone = CKRecordZone.ID(zoneName: "Backup", ownerName: CKCurrentUserDefaultName)
    let encoded = try CloudKitPlugin.archive(zone)
    XCTAssertNotNil(Data(base64Encoded: encoded))
    XCTAssertEqual(CloudKitPlugin.unarchive(CKRecordZone.ID.self, from: encoded), zone)

    XCTAssertNil(CloudKitPlugin.unarchiveToken(encoded))
    XCTAssertNil(CloudKitPlugin.unarchiveToken("not base64!"))
    XCTAssertNil(CloudKitPlugin.unarchiveToken(Data("garbage".utf8).base64EncodedString()))
  }

  func testPushCompletionQueueDeliversOutcomeAndTimeoutsFallback() {
    let queue = CloudKitPlugin.PushCompletionQueue()
    var first: String?
    queue.enqueue({ first = $0 }, timeoutSeconds: 10)
    queue.complete("newData")
    XCTAssertEqual(first, "newData")

    let timedOut = expectation(description: "push completion timeout")
    var second: String?
    queue.enqueue({
      second = $0
      timedOut.fulfill()
    }, timeoutSeconds: 0.05)
    waitForExpectations(timeout: 1.0)
    XCTAssertEqual(second, "noData")
  }

  func testPushCompletionQueuePreservesEarlierDeadlineAcrossOverlappingPushes() {
    let queue = CloudKitPlugin.PushCompletionQueue()
    let firstTimedOut = expectation(description: "first push keeps its earlier deadline")
    var first: String?
    var second: String?

    queue.enqueue({
      first = $0
      firstTimedOut.fulfill()
    }, timeoutSeconds: 0.05)
    // A second push arriving before the first finishes must not reset the
    // earlier deadline past Apple's ~30s background-fetch limit.
    queue.enqueue({ second = $0 }, timeoutSeconds: 10)

    waitForExpectations(timeout: 1.0)
    XCTAssertEqual(first, "noData")
    XCTAssertNil(second)

    queue.complete("newData")
    XCTAssertEqual(second, "newData")
  }
}
