import Cocoa

/// One row, as Dart's `NativeSidebarItem.toMap` sends it.
struct SidebarRowSpec: Equatable {
  let id: String
  let title: String
  let symbol: String
  let badge: String?
  let enabled: Bool

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
  }
}

/// A titled section (Servers) is a group header with children; untitled
/// sections contribute top-level rows, as on iPad.
enum SidebarNode: Equatable {
  case row(SidebarRowSpec)
  case group(title: String, rows: [SidebarRowSpec])
}

/// Turns a `setSidebar` payload into outline nodes.
func sidebarNodes(from payload: Any?) -> [SidebarNode] {
  let sections = ((payload as? [String: Any])?["sections"] as? [Any]) ?? []
  var nodes: [SidebarNode] = []
  for case let section as [String: Any] in sections {
    let rows = ((section["items"] as? [Any]) ?? []).compactMap(SidebarRowSpec.init(channelValue:))
    if let title = section["title"] as? String, !title.isEmpty {
      nodes.append(.group(title: title, rows: rows))
    } else {
      nodes.append(contentsOf: rows.map(SidebarNode.row))
    }
  }
  return nodes
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

/// The macOS sidebar pane: a source-list outline view of the rows Dart sends
/// over `mydia/native-tab-bar`.
///
/// Dart owns selection. A click or arrow key reports the row through
/// `onSelect` and leaves the highlight alone; Dart navigates and calls
/// `select` back, which is the only thing that moves the highlight.
final class MydiaSidebarViewController: NSViewController, NSOutlineViewDataSource,
  NSOutlineViewDelegate
{
  /// Called with a row's id when the viewer picks an enabled row.
  var onSelect: ((String) -> Void)?

  private let outlineView = NSOutlineView()
  private var lastNodes: [SidebarNode]?
  private var items: [SidebarItem] = []
  private var itemsById: [String: SidebarItem] = [:]
  private var selectedId: String?

  private static let cellId = NSUserInterfaceItemIdentifier("SidebarRow")
  private static let groupCellId = NSUserInterfaceItemIdentifier("SidebarGroup")
  private static let badgeTag = 1

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.style = .sourceList
    outlineView.headerView = nil
    outlineView.floatsGroupRows = false
    outlineView.rowSizeStyle = .default
    outlineView.allowsEmptySelection = true
    outlineView.dataSource = self
    outlineView.delegate = self

    let scrollView = NSScrollView()
    scrollView.documentView = outlineView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    view = scrollView
  }

  /// Shows `nodes`, keeping the current selection. A payload equal to the
  /// last one is ignored.
  func apply(_ nodes: [SidebarNode]) {
    guard nodes != lastNodes else { return }
    lastNodes = nodes
    itemsById = [:]
    items = nodes.map { node in
      switch node {
      case .row(let spec):
        return remember(SidebarItem(row: spec))
      case .group(let title, let rows):
        return SidebarItem(
          groupTitle: title, children: rows.map { remember(SidebarItem(row: $0)) })
      }
    }
    outlineView.reloadData()
    outlineView.expandItem(nil, expandChildren: true)
    applySelection(logMissing: false)
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
      return
    }
    guard let item = itemsById[id], case let row = outlineView.row(forItem: item), row >= 0 else {
      if logMissing { NSLog("[NativeTabBar] select: unknown tab id %@", id) }
      outlineView.deselectAll(nil)
      return
    }
    outlineView.selectRowIndexes([row], byExtendingSelection: false)
  }

  // MARK: NSOutlineViewDataSource

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let item = item as? SidebarItem else { return items.count }
    return item.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let item = item as? SidebarItem else { return items[index] }
    return item.children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    (item as? SidebarItem)?.isGroup ?? false
  }

  // MARK: NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
    (item as? SidebarItem)?.isGroup ?? false
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
    if let spec = (item as? SidebarItem)?.row, spec.enabled {
      onSelect?(spec.id)
    }
    return false
  }

  func outlineView(
    _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
  ) -> NSView? {
    guard let item = item as? SidebarItem else { return nil }
    if let title = item.groupTitle {
      let cell = dequeue(Self.groupCellId) { Self.makeGroupCell() }
      cell.textField?.stringValue = title
      return cell
    }
    guard let spec = item.row else { return nil }
    let cell = dequeue(Self.cellId) { Self.makeRowCell() }
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

  private func dequeue(
    _ id: NSUserInterfaceItemIdentifier, make: () -> NSTableCellView
  ) -> NSTableCellView {
    if let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
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
