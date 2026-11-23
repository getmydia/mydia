/// The desktop settings dialog's frame: a category sidebar beside a pane,
/// each category with its own navigator so drilling into a server and
/// switching to Diagnostics and back keeps your place.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/palette.dart';
import '../../../../l10n/l10n.dart';
import 'settings_dialog_sidebar.dart';

enum SettingsCategory {
  connections(Icons.hub_outlined),
  backup(Icons.cloud_upload_outlined),
  playback(Icons.play_circle_outline),
  appearance(Icons.palette_outlined),
  diagnostics(Icons.lan_outlined),
  about(Icons.info_outline);

  const SettingsCategory(this.icon);

  final IconData icon;

  /// The sidebar label, which is also the category's root page title.
  String label(AppLocalizations l10n) => switch (this) {
    connections => l10n.connectionsTitle,
    backup => l10n.backupSectionTitle,
    playback => l10n.settingsPlayback,
    appearance => l10n.settingsAppearanceSection,
    diagnostics => l10n.settingsDiagnostics,
    about => l10n.settingsAbout,
  };

  /// The one line under the pane title. Null for connections, whose page
  /// opens with its own constellation.
  String? description(AppLocalizations l10n) => switch (this) {
    connections => null,
    backup => l10n.settingsBackupDescription,
    playback => l10n.settingsPlaybackDescription,
    appearance => l10n.settingsAppearanceDescription,
    diagnostics => l10n.settingsDiagnosticsDescription,
    about => l10n.settingsAboutDescription,
  };

  /// True when the sidebar sets this category apart from the ones above it.
  bool get startsGroup => this == diagnostics;
}

class SettingsDialogController extends ValueNotifier<SettingsCategory> {
  SettingsDialogController(super.initial, {String? connectionsSection})
    : connectionsSection = ValueNotifier<String?>(connectionsSection);

  /// A section the connections pane should scroll to (`'devices'`). Set
  /// before the dialog opens, the pane takes it as it mounts; set while it
  /// is open, the dialog returns the pane to the hub and selects it.
  final ValueNotifier<String?> connectionsSection;

  /// False once disposed. `openSettings` disposes the controller as soon as
  /// `showDialog` completes, which is when the dialog starts closing, so the
  /// panes (and a toast action holding their nav) can outlive it briefly.
  bool get isOpen => !_disposed;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    connectionsSection.dispose();
    super.dispose();
  }
}

/// Below this the dialog takes the whole window and the sidebar drops its
/// labels.
const Size kSettingsDialogCompactBelow = Size(640, 420);
const Size kSettingsDialogSize = Size(880, 600);
const double kSettingsDialogInset = 24;

typedef SettingsSidebarBuilder = Widget Function(
  SettingsCategory selected,
  bool compact,
  ValueChanged<SettingsCategory> onSelect,
);

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.rootPage,
    this.wrapPane,
    this.sidebar,
  });

  final SettingsDialogController controller;
  final Widget Function(SettingsCategory category) rootPage;
  final Widget Function(BuildContext context, Widget child)? wrapPane;

  /// Builds the sidebar. `openSettings` passes one that wires the account,
  /// connection and update status; without it the dialog draws the plain
  /// sidebar, so it pumps without a `ProviderScope`.
  final SettingsSidebarBuilder? sidebar;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _navigators = {
    for (final c in SettingsCategory.values) c: GlobalKey<NavigatorState>(),
  };

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    // Added before any pane mounts, so this runs ahead of the connections
    // pane taking (and clearing) the request.
    widget.controller.connectionsSection.addListener(_sectionRequested);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.connectionsSection.removeListener(_sectionRequested);
    super.dispose();
  }

  void _changed() => setState(() {});

  /// A section lives on the hub: back to its root, then show the pane.
  void _sectionRequested() {
    if (widget.controller.connectionsSection.value == null) return;
    _navigators[SettingsCategory.connections]!.currentState?.popUntil(
      (route) => route.isFirst,
    );
    widget.controller.value = SettingsCategory.connections;
  }

  void _close() => Navigator.of(context).pop();

  void _select(SettingsCategory c) => widget.controller.value = c;

  /// Esc: one level back in the pane, or out of the dialog at a root.
  void _escape() {
    final pane = _navigators[widget.controller.value]!.currentState;
    if (pane != null && pane.canPop()) {
      pane.pop();
    } else {
      _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final window = MediaQuery.sizeOf(context);
    final compact =
        window.width < kSettingsDialogCompactBelow.width ||
        window.height < kSettingsDialogCompactBelow.height;
    final inset = compact ? 0.0 : kSettingsDialogInset;
    final size = Size(
      (window.width - inset * 2).clamp(0, kSettingsDialogSize.width),
      (window.height - inset * 2).clamp(0, kSettingsDialogSize.height),
    );
    final selected = widget.controller.value;

    return SettingsDialogScope(
      close: _close,
      isOpen: () => widget.controller.isOpen,
      select: (c) => widget.controller.value = c,
      paneNavigator: (c) => _navigators[c]?.currentState,
      connectionsSection: widget.controller.connectionsSection,
      child: Dialog(
        insetPadding: EdgeInsets.all(inset),
        backgroundColor: palette.background,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            compact ? 0 : AppTheme.radiusCard,
          ),
        ),
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _escape},
          child: Focus(
            autofocus: true,
            child: SizedBox.fromSize(
              key: const Key('settings-dialog'),
              size: size,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  widget.sidebar?.call(selected, compact, _select) ??
                      SettingsDialogSidebar(
                        selected: selected,
                        compact: compact,
                        onSelect: _select,
                      ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: palette.divider,
                  ),
                  Expanded(
                    child: IndexedStack(
                      index: selected.index,
                      children: [
                        for (final c in SettingsCategory.values)
                          _pane(context, c),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pane(BuildContext context, SettingsCategory category) {
    final navigator = Navigator(
      key: _navigators[category],
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(builder: (_) => widget.rootPage(category)),
      ],
    );
    // A Builder so `wrapPane` gets a context under SettingsDialogScope.
    return Builder(
      builder: (context) =>
          widget.wrapPane?.call(context, navigator) ?? navigator,
    );
  }
}

class SettingsDialogScope extends InheritedWidget {
  const SettingsDialogScope({
    super.key,
    required this.close,
    required this.isOpen,
    required this.select,
    required this.paneNavigator,
    required this.connectionsSection,
    required super.child,
  });

  /// False once the dialog's controller is disposed: [select] and
  /// [connectionsSection] must not be written then.
  final bool Function() isOpen;

  final VoidCallback close;
  final ValueChanged<SettingsCategory> select;

  /// The pane's navigator, or null once the dialog is gone: a flow that
  /// awaited (a removal, say) can call back after the dialog closed.
  final NavigatorState? Function(SettingsCategory category) paneNavigator;

  /// A section the connections pane should scroll to (`'devices'`). The pane
  /// stays mounted, so a request arrives here rather than as a new route;
  /// the pane clears it once handed to the hub.
  final ValueNotifier<String?> connectionsSection;

  static SettingsDialogScope of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<SettingsDialogScope>();
    assert(scope != null, 'SettingsDialogScope.of outside a SettingsDialog');
    return scope!;
  }

  @override
  bool updateShouldNotify(SettingsDialogScope oldWidget) => false;
}

/// One page in the dialog's pane: a header row over scrolling content.
class SettingsPane extends StatelessWidget {
  const SettingsPane({
    super.key,
    required this.title,
    this.description,
    this.actions = const [],
    this.capWidth = true,
    required this.child,
  });

  /// Null when the content opens with its own title, so only the header
  /// row's controls show above it.
  final String? title;
  final String? description;
  final List<Widget> actions;

  /// Caps the content at 680 (600 plus the body padding). The connections hub
  /// sets this false: it has its own cap and centering.
  final bool capWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    final palette = context.palette;
    final heading = title;
    final blurb = description;
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 8),
                if (canPop)
                  IconButton(
                    key: const Key('settings-dialog-back'),
                    tooltip: context.l10n.commonBack,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                const Spacer(),
                ...actions,
                IconButton.filledTonal(
                  key: const Key('settings-dialog-close'),
                  tooltip: context.l10n.commonClose,
                  icon: const Icon(Icons.close, size: 15),
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(30),
                    minimumSize: Size.zero,
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: SettingsDialogScope.of(context).close,
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          if (heading != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        heading,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (blurb != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          blurb,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: palette.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: capWidth
                ? Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: child,
                    ),
                  )
                : child,
          ),
        ],
      ),
    );
  }
}
