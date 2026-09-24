import Cocoa
import FlutterMacOS
import Sparkle

/// User-defaults key backing the track choice.
///
/// Swift owns this rather than Flutter because `allowedChannels(for:)` is a
/// synchronous Objective-C callback that must return a value immediately.
/// It cannot await an asynchronous round trip to Dart, so the source of
/// truth has to live on this side. Flutter reads and writes it through the
/// method channel below.
///
/// Settable without the UI for testing:
///   defaults write dev.mydia.player MydiaUpdateTrack -string beta
let updateTrackDefaultsKey = "MydiaUpdateTrack"

/// The previous boolean opt-in. Kept only so `currentUpdateTrack()` can
/// migrate an existing beta user onto the new track key the first time
/// nothing has been written under it, so they stay on beta after this
/// upgrade instead of dropping back to stable. No live code writes to this
/// key any more: the settings screen moved to the track picker, which calls
/// `setTrack` directly, and a track write always wins from then on.
///
/// Settable without the UI for testing:
///   defaults write dev.mydia.player MydiaBetaChannel -bool true
let legacyBetaChannelDefaultsKey = "MydiaBetaChannel"

/// Channels an item can be tagged with in the appcast. Stable items carry no
/// channel and are visible to everyone, which is what lets a beta user return
/// to stable on their own once a stable build number passes the beta they
/// are running.
let betaChannelName = "beta"
let devChannelName = "dev"

/// Resolves the track this installation follows, migrating the legacy
/// boolean opt-in the first time nothing has been written under the new key.
func currentUpdateTrack() -> String {
  if let stored = UserDefaults.standard.string(forKey: updateTrackDefaultsKey) {
    return stored
  }
  return UserDefaults.standard.bool(forKey: legacyBetaChannelDefaultsKey) ? betaChannelName : "stable"
}

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
    switch currentUpdateTrack() {
    case devChannelName:
      // A dev user sees beta items too: dev is a superset, so they are never
      // stranded below a beta that has already shipped.
      return [betaChannelName, devChannelName]
    case betaChannelName:
      return [betaChannelName]
    default:
      return []
    }
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var updaterController: SPUStandardUpdaterController!

  // Held here because SPUStandardUpdaterController does not retain its delegate.
  private let updaterDelegate = UpdaterDelegate()

  // Held here because menu items do not retain their target.
  private var appMenu: AppMenu?

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

      case "getTrack":
        result(currentUpdateTrack())

      case "setTrack":
        guard let track = call.arguments as? String,
          ["stable", betaChannelName, devChannelName].contains(track)
        else {
          result(
            FlutterError(
              code: "bad-arguments",
              message: "setTrack expects one of stable, beta, dev",
              details: nil
            ))
          return
        }
        UserDefaults.standard.set(track, forKey: updateTrackDefaultsKey)
        result(nil)
        // Sparkle reads allowedChannels on every check, so this takes effect
        // without a restart. Check immediately on anything but stable so the
        // choice does something visible instead of waiting for the next
        // scheduled check. result is answered first so the Dart future never
        // depends on how long Sparkle's check takes.
        if track != "stable" {
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
      case "performTitleBarDoubleClick":
        (self?.mainFlutterWindow as? MainFlutterWindow)?.performTitleBarDoubleClick()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let menu = AppMenu(messenger: controller.engine.binaryMessenger, window: mainFlutterWindow)
    if let mainMenu = NSApp.mainMenu {
      menu.install(in: mainMenu, updater: updaterController)
    }
    appMenu = menu
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return appMenu?.dockMenu()
  }
}
