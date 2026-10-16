import Cocoa

/// One row, as Dart's `NativeSidebarItem.toMap` sends it.
struct SidebarRowSpec: Equatable {
  let id: String
  let title: String
  let symbol: String
  let badge: String?
  let enabled: Bool
  /// A command (Edit sidebar) rather than a place to go.
  let isAction: Bool

  init?(channelValue: Any?) {
    guard let map = channelValue as? [String: Any],
      let id = map["id"] as? String,
      let title = map["title"] as? String,
      let symbol = map["symbol"] as? String
    else { return nil }
    self.id = id
    self.title = title
    self.symbol = symbol
    badge = map["badge"] as? String
    enabled = (map["enabled"] as? Bool) ?? true
    isAction = (map["kind"] as? String) == "action"
  }
}

/// A titled section (Servers) is a group header with children; untitled
/// sections contribute top-level rows, as on iPad.
enum SidebarNode: Equatable {
  case row(SidebarRowSpec)
  case group(title: String, rows: [SidebarRowSpec])
}

/// What the macOS sidebar shows for one `setSidebar` payload.
///
/// The `trailing` section (Edit sidebar, Downloads, Settings) is the app's
/// own, not the library's, so it leaves the scrolling list as the Mac
/// pattern has it: its places pin to a footer, and its commands move to the
/// sidebar's context menu and the View menu.
struct SidebarModel: Equatable {
  var nodes: [SidebarNode] = []
  var footer: [SidebarRowSpec] = []
  var commands: [SidebarRowSpec] = []

  init() {}

  init(payload: Any?) {
    let sections = ((payload as? [String: Any])?["sections"] as? [Any]) ?? []
    for case let section as [String: Any] in sections {
      let rows = ((section["items"] as? [Any]) ?? []).compactMap(
        SidebarRowSpec.init(channelValue:))
      if section["id"] as? String == "trailing" {
        footer += rows.filter { !$0.isAction }
        commands += rows.filter(\.isAction)
      } else if let title = section["title"] as? String, !title.isEmpty {
        nodes.append(.group(title: title, rows: rows))
      } else {
        nodes.append(contentsOf: rows.map(SidebarNode.row))
      }
    }
  }
}

/// The outline view's item. `NSOutlineView` keys items by identity, so each
/// node is wrapped in a reference type built per payload.
private final class SidebarItem: NSObject {
  let row: SidebarRowSpec?
  let groupTitle: String?
  let children: [SidebarItem]

  init(row: SidebarRowSpec) {
    self.row = row
    groupTitle = nil
    children = []
  }

  init(groupTitle: String, children: [SidebarItem]) {
    row = nil
    self.groupTitle = groupTitle
    self.children = children
  }

  var isGroup: Bool { groupTitle != nil }
}

/// The macOS sidebar pane: a scrolling source list of the rows Dart sends
/// over `mydia/native-tab-bar`, and a footer pinned below it for the app's
/// own places (see `SidebarModel`).
///
/// Dart owns selection. A click or arrow key reports the row through
/// `onSelect` and leaves the highlight alone; Dart navigates and calls
/// `select` back, which is the only thing that moves the highlight.
final class MydiaSidebarViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate
{
  /// Called with a row's id when the viewer picks an enabled row.
  var onSelect: ((String) -> Void)?

  /// The model's commands, for the View menu.
  private(set) var commands: [SidebarRowSpec] = []

  private let outlineView = NSOutlineView()
  private let footerView = NSOutlineView()
  private var footerHeight: NSLayoutConstraint?
  private var lastModel: SidebarModel?
  private var items: [SidebarItem] = []
  private var footerItems: [SidebarItem] = []
  private var itemsById: [String: SidebarItem] = [:]
  /// The group each grouped row sits in, to expand it for `select`.
  private var groupById: [String: SidebarItem] = [:]
  private var selectedId: String?
  /// The key press or click that last reported a row; see
  /// `selectionIndexesForProposedSelection`.
  private var reportedGesture: String?

  private static let cellId = NSUserInterfaceItemIdentifier("SidebarRow")
  private static let groupCellId = NSUserInterfaceItemIdentifier("SidebarGroup")
  private static let serverCellId = NSUserInterfaceItemIdentifier("SidebarServer")
  /// Dart's `kSourceHeaderId`: the current server's row, which opens the
  /// server picker. It is drawn as an avatar rather than a page row.
  private static let serverHeaderId = "action:source-header"
  private static let badgeTag = 1

  override func loadView() {
    let list = Self.scrollView(for: outlineView, delegate: self)
    list.hasVerticalScroller = true
    let footer = Self.scrollView(for: footerView, delegate: self)
    footer.verticalScrollElasticity = .none
    let separator = NSBox()
    separator.boxType = .separator

    let root = NSView()
    for view in [list, separator, footer] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    let height = footer.heightAnchor.constraint(equalToConstant: 0)
    footerHeight = height
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: root.topAnchor),
      list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      separator.topAnchor.constraint(equalTo: list.bottomAnchor),
      separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
      height,
    ])
    view = root
  }

  private static func scrollView(
    for outline: NSOutlineView, delegate: MydiaSidebarViewController
  ) -> NSScrollView {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.style = .sourceList
    outline.headerView = nil
    outline.floatsGroupRows = false
    outline.rowSizeStyle = .default
    outline.allowsEmptySelection = true
    // Cmd+A, Shift+arrow and Cmd+click would otherwise propose sets.
    outline.allowsMultipleSelection = false
    outline.dataSource = delegate
    outline.delegate = delegate

    let scrollView = NSScrollView()
    scrollView.documentView = outline
    scrollView.drawsBackground = false
    return scrollView
  }

  /// Shows `model`, keeping the current selection. A model equal to the
  /// last one is ignored.
  func apply(_ model: SidebarModel) {
    guard model != lastModel else { return }
    lastModel = model
    itemsById = [:]
    groupById = [:]
    footerItems = model.footer.map { remember(SidebarItem(row: $0)) }
    commands = model.commands
    items = model.nodes.map { node in
      switch node {
      case .row(let spec):
        return remember(SidebarItem(row: spec))
      case .group(let title, let rows):
        let group = SidebarItem(
          groupTitle: title, children: rows.map { remember(SidebarItem(row: $0)) })
        for row in rows { groupById[row.id] = group }
        return group
      }
    }
    outlineView.reloadData()
    outlineView.expandItem(nil, expandChildren: true)
    footerView.reloadData()
    let rows = footerView.numberOfRows
    footerHeight?.constant = rows > 0 ? footerView.rect(ofRow: rows - 1).maxY : 0
    let menu = commandMenu()
    outlineView.menu = menu
    footerView.menu = menu
    applySelection(logMissing: false)
  }

  /// Runs the command row `id` (Edit sidebar) the way a click on its row
  /// used to.
  func perform(command id: String) {
    guard let spec = commands.first(where: { $0.id == id }), spec.enabled else { return }
    onSelect?(spec.id)
  }

  private func commandMenu() -> NSMenu? {
    guard !commands.isEmpty else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    for spec in commands {
      let item = NSMenuItem(
        title: "\(spec.title)…", action: #selector(commandChosen(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = spec.id
      item.isEnabled = spec.enabled
      menu.addItem(item)
    }
    return menu
  }

  @objc private func commandChosen(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { perform(command: id) }
  }

  /// Highlights the row with `id`, or clears the highlight for nil.
  func select(_ id: String?) {
    selectedId = id
    applySelection(logMissing: true)
  }

  private func remember(_ item: SidebarItem) -> SidebarItem {
    if let id = item.row?.id { itemsById[id] = item }
    return item
  }

  private func applySelection(logMissing: Bool) {
    guard let id = selectedId else {
      outlineView.deselectAll(nil)
      footerView.deselectAll(nil)
      return
    }
    // A row inside a group the viewer collapsed has no row index until the
    // group opens.
    if let group = groupById[id], !outlineView.isItemExpanded(group) {
      outlineView.expandItem(group)
    }
    let inFooter = footerItems.contains { $0.row?.id == id }
    let target = inFooter ? footerView : outlineView
    (inFooter ? outlineView : footerView).deselectAll(nil)
    guard let item = itemsById[id], case let row = target.row(forItem: item), row >= 0 else {
      if logMissing { NSLog("[NativeTabBar] select: unknown tab id %@", id) }
      target.deselectAll(nil)
      return
    }
    target.selectRowIndexes([row], byExtendingSelection: false)
  }

  // MARK: NSOutlineViewDataSource

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item = item as? SidebarItem else { return roots(of: outlineView).count }
    return item.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let item = item as? SidebarItem else { return roots(of: outlineView)[index] }
    return item.children[index]
  }

  private func roots(of outline: NSOutlineView) -> [SidebarItem] {
    outline === footerView ? footerItems : items
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? SidebarItem)?.isGroup ?? false
  }

  // MARK: NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    (item as? SidebarItem)?.isGroup ?? false
  }

  /// Reports the viewer's pick and keeps the selection where Dart put it.
  ///
  /// Because the answer never changes the selection, AppKit does not stop
  /// at one proposal: a single Down arrow proposes every following row in
  /// turn (observed: one key press, twelve proposals), and a click proposes
  /// its row twice on the mouse-up (never on the mouse-down). So only the
  /// first enabled row a given key press or click proposes is reported,
  /// which also skips group headers and disabled rows on the way. Drags
  /// report nothing. `shouldSelectItem` is not implemented; AppKit skips it
  /// when this is.
  func outlineView(
    _ outlineView: NSOutlineView,
    selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
  ) -> IndexSet {
    guard let event = NSApp.currentEvent,
      let gesture = Self.gesture(of: event),
      gesture != reportedGesture,
      let row = proposedSelectionIndexes.first,
      let spec = (outlineView.item(atRow: row) as? SidebarItem)?.row, spec.enabled
    else {
      return outlineView.selectedRowIndexes
    }
    reportedGesture = gesture
    onSelect?(spec.id)
    return outlineView.selectedRowIndexes
  }

  /// Identifies the key press or click `event` belongs to, or nil for events
  /// that never report. A click's down and up share an `eventNumber`;
  /// `eventNumber` is only valid on mouse events, so key presses use their
  /// timestamp.
  private static func gesture(of event: NSEvent) -> String? {
    switch event.type {
    case .keyDown: return "key \(event.timestamp)"
    case .leftMouseDown, .leftMouseUp: return "click \(event.eventNumber)"
    default: return nil
    }
  }

  func outlineView(
    _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
  ) -> NSView? {
    guard let item = item as? SidebarItem else { return nil }
    if let title = item.groupTitle {
      let cell = dequeue(Self.groupCellId, in: outlineView) { Self.makeGroupCell() }
      cell.textField?.stringValue = title
      return cell
    }
    guard let spec = item.row else { return nil }
    if spec.id == Self.serverHeaderId {
      let cell = dequeue(Self.serverCellId, in: outlineView) { ServerHeaderCell() }
      (cell as? ServerHeaderCell)?.show(name: spec.title, enabled: spec.enabled)
      return cell
    }
    let cell = dequeue(Self.cellId, in: outlineView) { Self.makeRowCell() }
    cell.textField?.stringValue = spec.title
    cell.textField?.textColor = spec.enabled ? .labelColor : .disabledControlTextColor
    cell.imageView?.image = Self.symbolImage(spec.symbol, description: spec.title)
    cell.imageView?.alphaValue = spec.enabled ? 1 : 0.4
    if let badge = cell.viewWithTag(Self.badgeTag) as? NSTextField {
      badge.stringValue = spec.badge ?? ""
      badge.isHidden = spec.badge == nil
    }
    return cell
  }

  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    (item as? SidebarItem)?.row?.id == Self.serverHeaderId ? 44 : outlineView.rowHeight
  }

  private func dequeue(
    _ id: NSUserInterfaceItemIdentifier, in outline: NSOutlineView,
    make: () -> NSTableCellView
  ) -> NSTableCellView {
    if let cell = outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
      return cell
    }
    let cell = make()
    cell.identifier = id
    return cell
  }

  private static func symbolImage(_ name: String, description: String) -> NSImage? {
    if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
      return image
    }
    NSLog("[NativeTabBar] unknown SF Symbol %@, using circle", name)
    return NSImage(systemSymbolName: "circle", accessibilityDescription: description)
  }

  private static func makeGroupCell() -> NSTableCellView {
    let cell = NSTableCellView()
    let text = NSTextField(labelWithString: "")
    text.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(text)
    cell.textField = text
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  private static func makeRowCell() -> NSTableCellView {
    let cell = NSTableCellView()
    let image = NSImageView()
    let text = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    badge.tag = badgeTag
    badge.textColor = .secondaryLabelColor
    badge.alignment = .right
    text.lineBreakMode = .byTruncatingTail
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    for view in [image, text, badge] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(view)
    }
    cell.imageView = image
    cell.textField = text
    NSLayoutConstraint.activate([
      image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 18),
      text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
      text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      badge.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
      badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}

/// The server switcher row: an initials avatar, the server's name, and the
/// up-down chevron macOS uses for a picker.
private final class ServerHeaderCell: NSTableCellView {
  private let avatar = NSView()
  private let initials = NSTextField(labelWithString: "")
  private let name = NSTextField(labelWithString: "")
  private let chevron = NSImageView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    avatar.wantsLayer = true
    avatar.layer?.cornerRadius = 14
    initials.font = .systemFont(ofSize: 11, weight: .semibold)
    initials.textColor = .white
    initials.alignment = .center
    name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    name.lineBreakMode = .byTruncatingTail
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    chevron.image = NSImage(
      systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Switch server")
    chevron.contentTintColor = .secondaryLabelColor
    chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
    for view in [avatar, initials, name, chevron] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    textField = name
    NSLayoutConstraint.activate([
      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatar.widthAnchor.constraint(equalToConstant: 28),
      avatar.heightAnchor.constraint(equalToConstant: 28),
      initials.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
      initials.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
      name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevron.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
      chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func show(name title: String, enabled: Bool) {
    name.stringValue = title
    name.textColor = enabled ? .labelColor : .disabledControlTextColor
    initials.stringValue = Self.initials(of: title)
    avatar.layer?.backgroundColor = Self.color(for: title).cgColor
    alphaValue = enabled ? 1 : 0.5
    setAccessibilityLabel("\(title), switch server")
  }

  /// Up to two letters: the first of the first two words, or the first two
  /// of a single word.
  static func initials(of title: String) -> String {
    let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    let letters =
      words.count >= 2
      ? words.prefix(2).compactMap(\.first).map(String.init).joined()
      : String(words.first?.prefix(2) ?? "?")
    return letters.uppercased()
  }

  /// A stable colour per server name, so each server keeps its avatar.
  static func color(for title: String) -> NSColor {
    let palette: [NSColor] = [
      .systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemIndigo,
      .systemGreen, .systemRed,
    ]
    let hash = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    return palette[Int(hash % UInt32(palette.count))]
  }
}
