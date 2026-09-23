import Cocoa
import FlutterMacOS
import Sparkle

/// Matched literally by `kAppMenuChannel` in
/// `lib/core/app_menu/app_menu_channel.dart`, which documents the contract.
let appMenuChannelName = "dev.mydia.player/app_menu"

/// What the Dock menu shows while something plays. Pushed from Dart, because
/// `applicationDockMenu` is synchronous and cannot wait on a round trip.
struct NowPlayingState {
  let title: String
  let isPlaying: Bool
  let hasNext: Bool
}

enum HelpLink {
  static let documentation = URL(string: "https://docs.mydia.dev")!
  static let releaseNotes = URL(string: "https://github.com/getmydia/mydia/releases")!
  static let reportIssue = URL(string: "https://github.com/getmydia/mydia/issues/new/choose")!
}

/// Owns the menu bar's Mydia-specific items and the Dock menu.
///
/// The xib's menu is reshaped here at launch rather than edited in Interface
/// Builder, so every item and shortcut is reviewable Swift. Menu items hold
/// their target weakly, so `AppDelegate` must keep this object alive.
final class AppMenu: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var nowPlaying: NowPlayingState?

  /// Edit items that do nothing in a Flutter view. Find's Cmd-F moves to Go.
  private static let deadEditItems: Set<String> = [
    "Find", "Spelling and Grammar", "Substitutions", "Transformations", "Speech",
  ]

  init(messenger: FlutterBinaryMessenger, window: NSWindow?) {
    channel = FlutterMethodChannel(name: appMenuChannelName, binaryMessenger: messenger)
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  func install(in mainMenu: NSMenu, updater: SPUStandardUpdaterController) {
    installAppMenuItems(mainMenu, updater: updater)
    pruneEditMenu(mainMenu)
    insertGoMenu(mainMenu)
    rebuildHelpMenu(mainMenu)
  }

  func dockMenu() -> NSMenu {
    let menu = NSMenu()
    if let state = nowPlaying {
      // No action, so the menu's auto-enabling shows it as a disabled label.
      menu.addItem(NSMenuItem(title: state.title, action: nil, keyEquivalent: ""))
      menu.addItem(item(state.isPlaying ? "Pause" : "Play", #selector(togglePlayPause(_:))))
      if state.hasNext {
        menu.addItem(item("Next Episode", #selector(nextEpisode(_:))))
      }
      menu.addItem(.separator())
    }
    menu.addItem(navItem("Search", route: "/search"))
    menu.addItem(navItem("Downloads", route: "/downloads"))
    menu.addItem(navItem("Settings", route: "/settings"))
    return menu
  }

  // MARK: - Menu bar

  private func installAppMenuItems(_ mainMenu: NSMenu, updater: SPUStandardUpdaterController) {
    guard let appMenu = mainMenu.items.first?.submenu else { return }

    if let settings = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
      settings.title = "Settings…"
      settings.target = self
      settings.action = #selector(openSettings(_:))
    }

    // Sparkle's controller validates this item itself, disabling it while a
    // check is already running.
    let check = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    check.target = updater
    appMenu.insertItem(check, at: min(1, appMenu.numberOfItems))
  }

  private func pruneEditMenu(_ mainMenu: NSMenu) {
    guard let edit = mainMenu.items.first(where: { $0.title == "Edit" })?.submenu else { return }
    for item in edit.items where AppMenu.deadEditItems.contains(item.title) {
      edit.removeItem(item)
    }
    collapseSeparators(edit)
  }

  private func insertGoMenu(_ mainMenu: NSMenu) {
    let go = NSMenu(title: "Go")
    go.addItem(navItem("Home", route: "/", key: "H"))
    go.addItem(navItem("Movies", route: "/movies", key: "1"))
    go.addItem(navItem("TV Shows", route: "/shows", key: "2"))
    go.addItem(navItem("Search", route: "/search", key: "f"))
    go.addItem(navItem("Downloads", route: "/downloads", key: "l", modifiers: [.command, .option]))
    go.addItem(.separator())
    go.addItem(item("Back", #selector(goBack(_:)), key: "["))

    let holder = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
    holder.submenu = go
    let windowIndex = mainMenu.items.firstIndex(where: { $0.title == "Window" })
    mainMenu.insertItem(holder, at: windowIndex ?? mainMenu.numberOfItems)
  }

  private func rebuildHelpMenu(_ mainMenu: NSMenu) {
    guard let help = mainMenu.items.first(where: { $0.title == "Help" })?.submenu else { return }
    help.removeAllItems()
    help.addItem(linkItem("Mydia Documentation", HelpLink.documentation))
    help.addItem(linkItem("Release Notes", HelpLink.releaseNotes))
    help.addItem(.separator())
    help.addItem(linkItem("Report an Issue…", HelpLink.reportIssue))
    // Keeps the system's search field at the top of Help.
    NSApp.helpMenu = help
  }

  /// Drops leading, trailing and repeated separators left behind by removals.
  private func collapseSeparators(_ menu: NSMenu) {
    var previousWasSeparator = true
    for item in menu.items {
      if item.isSeparatorItem && previousWasSeparator {
        menu.removeItem(item)
      } else {
        previousWasSeparator = item.isSeparatorItem
      }
    }
    if let last = menu.items.last, last.isSeparatorItem {
      menu.removeItem(last)
    }
  }

  // MARK: - Item builders

  private func item(
    _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    return item
  }

  private func navItem(
    _ title: String, route: String, key: String = "",
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let menuItem = item(title, #selector(navigate(_:)), key: key, modifiers: modifiers)
    menuItem.representedObject = route
    return menuItem
  }

  private func linkItem(_ title: String, _ url: URL) -> NSMenuItem {
    let menuItem = item(title, #selector(openLink(_:)))
    menuItem.representedObject = url
    return menuItem
  }

  // MARK: - Actions

  @objc private func navigate(_ sender: NSMenuItem) {
    guard let route = sender.representedObject as? String else { return }
    send("navigate", route)
  }

  @objc private func openSettings(_ sender: Any?) {
    send("navigate", "/settings")
  }

  @objc private func goBack(_ sender: Any?) {
    channel.invokeMethod("back", arguments: nil)
  }

  // Playback controls deliberately leave the window where it is: controlling
  // playback from the Dock without switching to the app is the point.
  @objc private func togglePlayPause(_ sender: Any?) {
    channel.invokeMethod("togglePlayPause", arguments: nil)
  }

  @objc private func nextEpisode(_ sender: Any?) {
    channel.invokeMethod("nextEpisode", arguments: nil)
  }

  @objc private func openLink(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.open(url)
  }

  /// Brings the window forward first, so a Dock shortcut chosen while the app
  /// is in the background shows the screen it opened.
  private func send(_ method: String, _ route: String) {
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    channel.invokeMethod(method, arguments: route)
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "setNowPlaying":
      guard let args = call.arguments as? [String: Any],
        let title = args["title"] as? String,
        let isPlaying = args["isPlaying"] as? Bool,
        let hasNext = args["hasNext"] as? Bool
      else {
        result(
          FlutterError(
            code: "bad-arguments",
            message: "setNowPlaying expects {title, isPlaying, hasNext}",
            details: nil
          ))
        return
      }
      nowPlaying = NowPlayingState(title: title, isPlaying: isPlaying, hasNext: hasNext)
      result(nil)

    case "clearNowPlaying":
      nowPlaying = nil
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
