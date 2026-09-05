import Cocoa
import FlutterMacOS
import Sparkle

/// User-defaults key backing the beta channel opt-in.
///
/// Swift owns this rather than Flutter because `allowedChannels(for:)` is a
/// synchronous Objective-C callback that must return a value immediately.
/// It cannot await an asynchronous round trip to Dart, so the source of
/// truth has to live on this side. Flutter reads and writes it through the
/// method channel below.
///
/// Settable without the UI for testing:
///   defaults write dev.mydia.player MydiaBetaChannel -bool true
let betaChannelDefaultsKey = "MydiaBetaChannel"

/// The Sparkle channel prerelease items are tagged with in the appcast.
let betaChannelName = "beta"

/// Reports the user's channel choice to Sparkle on every update check.
///
/// Items with no <sparkle:channel> are visible to everyone, so a user on the
/// beta channel still sees stable releases and returns to the stable track on
/// their own once a stable build number passes the beta they are running.
///
/// Lives in this file rather than its own because adding a Swift file to the
/// Runner target means hand-editing project.pbxproj, which is not worth it for
/// ten lines.
class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    UserDefaults.standard.bool(forKey: betaChannelDefaultsKey) ? [betaChannelName] : []
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var updaterController: SPUStandardUpdaterController!

  // Held here because SPUStandardUpdaterController does not retain its delegate.
  private let updaterDelegate = UpdaterDelegate()

  override func applicationDidFinishLaunching(_ notification: Notification) {
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: updaterDelegate,
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

      case "getBetaChannel":
        result(UserDefaults.standard.bool(forKey: betaChannelDefaultsKey))

      case "setBetaChannel":
        guard let enabled = call.arguments as? Bool else {
          result(
            FlutterError(
              code: "bad-arguments",
              message: "setBetaChannel expects a boolean argument",
              details: nil
            ))
          return
        }
        UserDefaults.standard.set(enabled, forKey: betaChannelDefaultsKey)
        result(nil)
        // Sparkle reads allowedChannels on every check, so this takes effect
        // without a restart. Check immediately on opt-in so the toggle does
        // something visible instead of waiting for the next scheduled check.
        // result is answered first so the Dart future never depends on how
        // long Sparkle's check takes.
        if enabled {
          self?.updaterController.checkForUpdates(nil)
        }

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
