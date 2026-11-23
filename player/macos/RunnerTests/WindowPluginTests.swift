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

/// Clearing the aspect lock. `contentAspectRatio = .zero` crashed the exit
/// from fullscreen: it resets `resizeIncrements` to zero, and AppKit rounds
/// the restored frame to those increments.
final class WindowPluginAspectTests: XCTestCase {
  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
      styleMask: [.titled, .resizable], backing: .buffered, defer: true)
  }

  func testClearingTheLockKeepsUsableIncrements() {
    let window = makeWindow()
    WindowPlugin.applyAspectRatio(16.0 / 9.0, to: window)
    WindowPlugin.applyAspectRatio(0, to: window)

    XCTAssertEqual(window.resizeIncrements, NSSize(width: 1, height: 1))
    XCTAssertEqual(window.contentResizeIncrements, NSSize(width: 1, height: 1))
    // Unlocked reads as zero on a fresh window too.
    XCTAssertEqual(window.contentAspectRatio, .zero)
  }

  func testAfterClearingAFrameOfAnyShapeIsKept() {
    let window = makeWindow()
    WindowPlugin.applyAspectRatio(16.0 / 9.0, to: window)
    WindowPlugin.applyAspectRatio(0, to: window)

    let target = window.frameRect(forContentRect: NSRect(x: 100, y: 100, width: 800, height: 300))
    window.setFrame(target, display: false)
    XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 800, height: 300))
  }

  func testALockIsApplied() {
    let window = makeWindow()
    WindowPlugin.applyAspectRatio(2, to: window)
    XCTAssertEqual(window.contentAspectRatio.width / window.contentAspectRatio.height, 2, accuracy: 0.001)
  }
}
