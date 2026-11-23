import Cocoa
import FlutterMacOS
import XCTest

@testable import Mydia_Player

/// The rect conversion `WindowPlugin` applies at the channel boundary. Dart
/// sees top-left rects measured from the primary screen, the convention
/// nativeapi used, so geometry saved by earlier builds stays valid.
final class WindowPluginTests: XCTestCase {
  func testTopLeftOnPrimary() {
    let rect = WindowPlugin.topLeftRect(
      NSRect(x: 100, y: 200, width: 800, height: 600), primaryHeight: 1000)
    // 1000 - 200 - 600
    XCTAssertEqual(rect, NSRect(x: 100, y: 200, width: 800, height: 600))
  }

  func testTopLeftOnPrimaryNearTheBottom() {
    let rect = WindowPlugin.topLeftRect(
      NSRect(x: 0, y: 0, width: 800, height: 600), primaryHeight: 1000)
    XCTAssertEqual(rect.origin.y, 400)
  }

  func testSecondScreenAboveRoundTrips() {
    // A window on a screen stacked above a 1000pt primary.
    let frame = NSRect(x: 0, y: 1100, width: 800, height: 600)
    let rect = WindowPlugin.topLeftRect(frame, primaryHeight: 1000)
    XCTAssertEqual(rect.origin.y, -700)
    XCTAssertEqual(WindowPlugin.appKitFrame(rect, primaryHeight: 1000), frame)
  }
}
