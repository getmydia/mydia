#if os(iOS)
import Flutter
import UIKit
#else
import Cocoa
import FlutterMacOS
#endif
import CloudKit

/// Owns `mydia/cloudkit` and `mydia/cloudkit/changes`
/// (lib/core/backup/cloud/cloudkit_backend.dart): the backup slots in the
/// iCloud private database. Each device's slot is one `Slot` record named
/// `slot-<slotId>` in the custom zone `Backup`, its body a `CKAsset`.
///
/// The same source lives in ios/Runner and macos/Runner; keep them identical.
/// iOS registers it as a plugin so `FlutterAppDelegate` forwards silent
/// pushes to it; macOS has no plugin hook for pushes, so its `AppDelegate`
/// forwards them to `handleRemoteNotification`.
final class CloudKitPlugin: NSObject, FlutterStreamHandler {
  static let channelName = "mydia/cloudkit"
  static let eventChannelName = "mydia/cloudkit/changes"
  static let containerIdentifier = "iCloud.dev.mydia.player"
  static let zoneName = "Backup"
  static let recordType = "Slot"
  static let recordNamePrefix = "slot-"
  static let subscriptionID = "backup-changes"

  /// Every field but `payload`, so a listing never downloads a body.
  static let listedKeys = ["slotId", "deviceName", "platform", "updatedAt", "size"]

  static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

  /// An error raised by this plugin itself, carrying its channel code.
  struct PluginError: Error {
    let code: String
  }

  private let channel: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var accountObserver: NSObjectProtocol?

  /// Created on first use: `CKContainer(identifier:)` raises when the
  /// iCloud entitlement is missing, and Dart only calls in once it gated
  /// iCloud on.
  private lazy var container = CKContainer(identifier: Self.containerIdentifier)
  private var database: CKDatabase { container.privateCloudDatabase }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    events = FlutterEventChannel(name: Self.eventChannelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    events.setStreamHandler(self)
    accountObserver = NotificationCenter.default.addObserver(
      forName: .CKAccountChanged, object: nil, queue: .main
    ) { [weak self] _ in
      self?.emit("account")
    }
  }

  deinit {
    if let accountObserver {
      NotificationCenter.default.removeObserver(accountObserver)
    }
  }

  // MARK: Pushes and events

  /// Emits a change when [userInfo] is the `backup-changes` subscription's
  /// push. Returns whether it was.
  @discardableResult
  func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard Self.isBackupPush(userInfo) else { return false }
    emit("push")
    return true
  }

  static func isBackupPush(_ userInfo: [AnyHashable: Any]) -> Bool {
    CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ kind: String) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(kind)
    }
  }

  // MARK: Method channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let work: () async throws -> Any?
    switch call.method {
    case "accountStatus":
      work = { try await self.accountStatus() }
    case "fetchChanges":
      let token = args["token"] as? String
      work = { try await self.fetchChanges(token: token) }
    case "fetchPayload":
      guard let slotId = args["slotId"] as? String else {
        return result(Self.badArguments(call.method))
      }
      work = { try await self.fetchPayload(slotId: slotId) }
    case "save":
      guard let slotId = args["slotId"] as? String,
        let deviceName = args["deviceName"] as? String,
        let platform = args["platform"] as? String,
        let bytes = args["bytes"] as? FlutterStandardTypedData
      else {
        return result(Self.badArguments(call.method))
      }
      work = {
        try await self.save(
          slotId: slotId, deviceName: deviceName, platform: platform, bytes: bytes.data)
        return nil
      }
    case "delete":
      guard let slotId = args["slotId"] as? String else {
        return result(Self.badArguments(call.method))
      }
      work = {
        try await self.delete(slotId: slotId)
        return nil
      }
    case "subscribe":
      work = {
        try await self.subscribe()
        return nil
      }
    default:
      return result(FlutterMethodNotImplemented)
    }
    Task {
      do {
        let value = try await work()
        await MainActor.run { result(value) }
      } catch {
        let flutterError = Self.flutterError(error)
        await MainActor.run { result(flutterError) }
      }
    }
  }

  private func accountStatus() async throws -> [String: Any] {
    let status = try await container.accountStatus()
    let name = Self.statusName(status)
    guard name == "available" else { return ["status": name] }
    let user = try await container.userRecordID()
    return ["status": name, "userRecordName": user.recordName]
  }

  /// Every change since [token] (nil: every record), looping `moreComing`.
  /// A missing zone is created; when a token was passed the zone's
  /// disappearance is still reported (`zoneNotFound`) so Dart drops what it
  /// knew and fetches from nil.
  private func fetchChanges(token encoded: String?) async throws -> [String: Any] {
    var token: CKServerChangeToken?
    if let encoded {
      guard let decoded = Self.unarchiveToken(encoded) else {
        throw PluginError(code: "changeTokenExpired")
      }
      token = decoded
    }
    do {
      return try await fetchAll(since: token)
    } catch let error where Self.errorCode(error) == "zoneNotFound" {
      try await createZone()
      if token != nil { throw error }
      return try await fetchAll(since: nil)
    }
  }

  private func fetchAll(since start: CKServerChangeToken?) async throws -> [String: Any] {
    var token = start
    var changed: [String: [String: Any]] = [:]
    var deleted = Set<String>()
    while true {
      let page = try await fetchPage(since: token)
      for record in page.changed {
        guard let map = Self.recordToMap(record), let slotId = map["slotId"] as? String else {
          continue
        }
        changed[slotId] = map
        deleted.remove(slotId)
      }
      for slotId in page.deleted {
        changed.removeValue(forKey: slotId)
        deleted.insert(slotId)
      }
      token = page.token
      if !page.moreComing { break }
    }
    guard let token else { throw PluginError(code: "other") }
    return [
      "records": Array(changed.values),
      "deleted": Array(deleted),
      "token": try Self.archiveToken(token),
    ]
  }

  private struct ChangePage {
    var changed: [CKRecord] = []
    var deleted: [String] = []
    var token: CKServerChangeToken
    var moreComing: Bool
  }

  private func fetchPage(since token: CKServerChangeToken?) async throws -> ChangePage {
    try await withCheckedThrowingContinuation { continuation in
      let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
        previousServerChangeToken: token, resultsLimit: nil, desiredKeys: Self.listedKeys)
      let operation = CKFetchRecordZoneChangesOperation(
        recordZoneIDs: [Self.zoneID], configurationsByRecordZoneID: [Self.zoneID: config])
      operation.fetchAllChanges = false
      operation.qualityOfService = .userInitiated

      // The operation runs its blocks serially.
      var changed: [CKRecord] = []
      var deleted: [String] = []
      var zoneResult: Result<(CKServerChangeToken, Bool), Error>?
      operation.recordWasChangedBlock = { _, result in
        if case .success(let record) = result { changed.append(record) }
      }
      operation.recordWithIDWasDeletedBlock = { recordID, _ in
        if let slotId = Self.slotId(fromRecordName: recordID.recordName) {
          deleted.append(slotId)
        }
      }
      operation.recordZoneFetchResultBlock = { _, result in
        switch result {
        case .success(let value):
          zoneResult = .success((value.serverChangeToken, value.moreComing))
        case .failure(let error):
          zoneResult = .failure(error)
        }
      }
      operation.fetchRecordZoneChangesResultBlock = { result in
        // The zone's own error (zoneNotFound, changeTokenExpired) first:
        // the operation's is a partial failure wrapping it.
        switch (zoneResult, result) {
        case (.failure(let error)?, _), (_, .failure(let error)):
          continuation.resume(throwing: error)
        case (.success(let value)?, .success):
          continuation.resume(
            returning: ChangePage(
              changed: changed, deleted: deleted, token: value.0, moreComing: value.1))
        case (nil, .success):
          continuation.resume(throwing: PluginError(code: "other"))
        }
      }
      database.add(operation)
    }
  }

  /// The record's body, or nil when there is no such record.
  private func fetchPayload(slotId: String) async throws -> Any? {
    do {
      let record = try await database.record(for: Self.recordID(slotId: slotId))
      guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
        return nil
      }
      return FlutterStandardTypedData(bytes: try Data(contentsOf: url))
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }

  /// Overwrites the record whatever its server state (`.allKeys`), creating
  /// the zone when missing.
  private func save(slotId: String, deviceName: String, platform: String, bytes: Data)
    async throws
  {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("mydia-slot-\(UUID().uuidString).json.gz")
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let record = Self.makeRecord(
      slotId: slotId, deviceName: deviceName, platform: platform, size: bytes.count,
      updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000), asset: CKAsset(fileURL: url))
    do {
      try await saveRecord(record)
    } catch let error where Self.errorCode(error) == "zoneNotFound" {
      try await createZone()
      try await saveRecord(record)
    }
  }

  private func saveRecord(_ record: CKRecord) async throws {
    let results = try await database.modifyRecords(
      saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
    if case .failure(let error)? = results.saveResults[record.recordID] { throw error }
  }

  /// A record or zone that is already gone counts as deleted.
  private func delete(slotId: String) async throws {
    let id = Self.recordID(slotId: slotId)
    do {
      let results = try await database.modifyRecords(
        saving: [], deleting: [id], savePolicy: .allKeys, atomically: false)
      if case .failure(let error)? = results.deleteResults[id] { throw error }
    } catch let error where Self.isAlreadyGone(error) {
      return
    }
  }

  /// Saves the `backup-changes` database subscription; saving it again
  /// replaces it, so this is idempotent.
  private func subscribe() async throws {
    let subscription = CKDatabaseSubscription(subscriptionID: Self.subscriptionID)
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    let results = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    if case .failure(let error)? = results.saveResults[Self.subscriptionID] { throw error }
  }

  private func createZone() async throws {
    let results = try await database.modifyRecordZones(
      saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
    if case .failure(let error)? = results.saveResults[Self.zoneID] { throw error }
  }

  // MARK: Pure helpers (RunnerTests/CloudKitPluginTests.swift)

  static func recordID(slotId: String) -> CKRecord.ID {
    CKRecord.ID(recordName: recordNamePrefix + slotId, zoneID: zoneID)
  }

  static func slotId(fromRecordName name: String) -> String? {
    guard name.hasPrefix(recordNamePrefix) else { return nil }
    let id = String(name.dropFirst(recordNamePrefix.count))
    return id.isEmpty ? nil : id
  }

  static func makeRecord(
    slotId: String, deviceName: String, platform: String, size: Int, updatedAtMs: Int64,
    asset: CKAsset?
  ) -> CKRecord {
    let record = CKRecord(recordType: recordType, recordID: recordID(slotId: slotId))
    record["slotId"] = slotId as NSString
    record["deviceName"] = deviceName as NSString
    record["platform"] = platform as NSString
    record["updatedAt"] = NSNumber(value: updatedAtMs)
    record["size"] = NSNumber(value: Int64(size))
    if let asset { record["payload"] = asset }
    return record
  }

  /// A listed record as the channel's map: `slotId`, `deviceName`,
  /// `platform`, `updatedAt` (ms), `size` and `tag` (the change tag, the
  /// slot version). Nil without a slot id or a tag. [tag] defaults to the
  /// record's change tag; tests pass one, as a local record has none.
  static func recordToMap(_ record: CKRecord, tag: String? = nil) -> [String: Any]? {
    guard
      let slotId = (record["slotId"] as? String)
        ?? Self.slotId(fromRecordName: record.recordID.recordName),
      let tag = tag ?? record.recordChangeTag
    else { return nil }
    var map: [String: Any] = ["slotId": slotId, "tag": tag]
    if let deviceName = record["deviceName"] as? String { map["deviceName"] = deviceName }
    if let platform = record["platform"] as? String { map["platform"] = platform }
    if let updatedAt = record["updatedAt"] as? NSNumber { map["updatedAt"] = updatedAt.int64Value }
    if let size = record["size"] as? NSNumber { map["size"] = size.int64Value }
    return map
  }

  static func statusName(_ status: CKAccountStatus) -> String {
    switch status {
    case .available: return "available"
    case .noAccount: return "noAccount"
    case .restricted: return "restricted"
    case .couldNotDetermine, .temporarilyUnavailable: return "temporarilyUnavailable"
    @unknown default: return "temporarilyUnavailable"
    }
  }

  /// The channel error code for [error]: `notAuthenticated`, `unavailable`,
  /// `quotaExceeded`, `zoneNotFound`, `changeTokenExpired`, `network` or
  /// `other`. A partial failure is coded by its first item's error.
  static func errorCode(_ error: Error) -> String {
    if let error = error as? PluginError { return error.code }
    guard let ckError = error as? CKError else {
      return (error as NSError).domain == NSURLErrorDomain ? "network" : "other"
    }
    switch ckError.code {
    case .partialFailure:
      if let first = ckError.partialErrorsByItemID?.values.first { return errorCode(first) }
      return "other"
    case .notAuthenticated:
      return "notAuthenticated"
    case .accountTemporarilyUnavailable, .managedAccountRestricted, .badContainer,
      .missingEntitlement, .permissionFailure:
      return "unavailable"
    case .quotaExceeded:
      return "quotaExceeded"
    case .zoneNotFound, .userDeletedZone:
      return "zoneNotFound"
    case .changeTokenExpired:
      return "changeTokenExpired"
    case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
      .zoneBusy:
      return "network"
    default:
      return "other"
    }
  }

  /// CloudKit's retry delay for [error] in milliseconds, if it gave one.
  static func retryAfterMs(_ error: Error) -> Int? {
    guard let ckError = error as? CKError else { return nil }
    if ckError.code == .partialFailure, let first = ckError.partialErrorsByItemID?.values.first {
      return retryAfterMs(first)
    }
    guard let seconds = ckError.retryAfterSeconds else { return nil }
    return Int(seconds * 1000)
  }

  static func isAlreadyGone(_ error: Error) -> Bool {
    if errorCode(error) == "zoneNotFound" { return true }
    guard let ckError = error as? CKError else { return false }
    if ckError.code == .partialFailure, let first = ckError.partialErrorsByItemID?.values.first {
      return isAlreadyGone(first)
    }
    return ckError.code == .unknownItem
  }

  static func flutterError(_ error: Error) -> FlutterError {
    let code = errorCode(error)
    var details: [String: Any]?
    if code == "network", let retry = retryAfterMs(error) { details = ["retryAfterMs": retry] }
    return FlutterError(code: code, message: error.localizedDescription, details: details)
  }

  static func badArguments(_ method: String) -> FlutterError {
    FlutterError(code: "other", message: "\(method): bad arguments", details: nil)
  }

  /// Base64 of [object] archived with secure coding.
  static func archive(_ object: NSObject & NSSecureCoding) throws -> String {
    try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
      .base64EncodedString()
  }

  /// The [type] archived in [base64], nil when it is not one.
  static func unarchive<T: NSObject & NSSecureCoding>(_ type: T.Type, from base64: String) -> T? {
    guard let data = Data(base64Encoded: base64) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data)
  }

  static func archiveToken(_ token: CKServerChangeToken) throws -> String {
    try archive(token)
  }

  static func unarchiveToken(_ base64: String) -> CKServerChangeToken? {
    unarchive(CKServerChangeToken.self, from: base64)
  }
}

#if os(iOS)
extension CloudKitPlugin: FlutterPlugin {
  /// Creates the plugin and has `FlutterAppDelegate` forward remote
  /// notifications to it. The registrar keeps it alive (`publish`).
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = CloudKitPlugin(messenger: registrar.messenger())
    registrar.addApplicationDelegate(plugin)
    registrar.publish(plugin)
  }

  /// Claims the backup subscription's silent push. The completion handler
  /// is called at once: Dart polls on the event, and a background launch
  /// gets the usual grace period to finish.
  func application(
    _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) -> Bool {
    guard handleRemoteNotification(userInfo) else { return false }
    completionHandler(.newData)
    return true
  }
}
#endif
