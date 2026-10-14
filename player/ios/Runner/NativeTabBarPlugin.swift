import Flutter
import UIKit

/// Owns `mydia/native-tab-bar` (lib/core/platform/native_tab_bar_channel.dart)
/// and drives `MydiaTabBarController` from it.
///
/// Created on every iOS version. Only an iOS 26 iPhone with a 26 SDK build
/// gets a controller attached; everywhere else `isSupported` answers false and
/// Dart never sends anything else.
final class NativeTabBarPlugin: NSObject {
  static let channelName = "mydia/native-tab-bar"

  private let channel: FlutterMethodChannel

  /// The attached `MydiaTabBarController`, typed loosely because that class
  /// only exists on iOS 26.
  private var controller: AnyObject?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  #if compiler(>=6.2)
  @available(iOS 26.0, *)
  func attach(_ tabs: MydiaTabBarController) {
    controller = tabs
    tabs.onTabSelected = { [weak self] id in
      self?.channel.invokeMethod("tabSelected", arguments: id)
    }
    tabs.onInsetsChanged = { [weak self] bottom in
      self?.channel.invokeMethod("insetsChanged", arguments: bottom)
    }
    tabs.onAccessoryTapped = { [weak self] in
      self?.channel.invokeMethod("accessoryTapped", arguments: nil)
    }
    tabs.onAccessoryPlayPause = { [weak self] in
      self?.channel.invokeMethod("accessoryPlayPause", arguments: nil)
    }
  }
  #endif

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let tabs = controller as? MydiaTabBarController {
      switch call.method {
      case "isSupported":
        result(true)
      case "setTabs":
        let specs = (call.arguments as? [Any] ?? []).compactMap(NativeTabSpec.init(channelValue:))
        tabs.setTabs(specs)
        result(nil)
      case "select":
        if let id = call.arguments as? String { tabs.select(id) }
        result(nil)
      case "setVisible":
        tabs.setBarVisible((call.arguments as? Bool) ?? false)
        result(nil)
      case "setAccessory":
        tabs.setAccessory(CastAccessoryModel(channelValue: call.arguments))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
      return
    }
    #endif
    if call.method == "isSupported" {
      result(false)
    } else {
      result(nil)
    }
  }
}
