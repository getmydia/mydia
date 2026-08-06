import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  private var updaterController: SPUStandardUpdaterController!

  override func applicationDidFinishLaunching(_ notification: Notification) {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "dev.mydia.player/sparkle",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "checkForUpdates":
        self?.updaterController.checkForUpdates(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let chromeChannel = FlutterMethodChannel(
      name: "dev.mydia.player/window_chrome",
      binaryMessenger: controller.engine.binaryMessenger
    )
    chromeChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setTrafficLightsHidden":
        let hidden = (call.arguments as? [String: Any])?["hidden"] as? Bool ?? false
        self?.mainFlutterWindow?.standardWindowButton(.closeButton)?.isHidden = hidden
        self?.mainFlutterWindow?.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        self?.mainFlutterWindow?.standardWindowButton(.zoomButton)?.isHidden = hidden
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
