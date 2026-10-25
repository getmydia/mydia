/// The desktop settings dialog's frame: a category sidebar beside a pane,
/// each category with its own navigator so drilling into a server and
/// switching to Diagnostics and back keeps your place.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/palette.dart';
import '../../../../l10n/l10n.dart';
import 'settings_dialog_sidebar.dart';

enum SettingsCategory {
  playback(Icons.play_circle_outline),
  servers(Icons.dns_rounded),
  diagnostics(Icons.lan_outlined),
  about(Icons.info_outline);

  const SettingsCategory(this.icon);

  final IconData icon;

  /// The sidebar label, which is also the category's root page title.
  String label(AppLocalizations l10n) => switch (this) {
        playback => l10n.settingsPlayback,
        servers => l10n.settingsServers,
        diagnostics => l10n.settingsDiagnostics,
        about => l10n.settingsAbout,
      };
}

class SettingsDialogController extends ValueNotifier<SettingsCategory> {
  SettingsDialogController(super.initial);
}

/// Below this the dialog takes the whole window and the sidebar drops its
/// labels.
const Size kSettingsDialogCompactBelow = Size(640, 420);
const Size kSettingsDialogSize = Size(880, 600);
const double kSettingsDialogInset = 24;

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.rootPage,
    this.wrapPane,
  });

  final SettingsDialogController controller;
  final Widget Function(SettingsCategory category) rootPage;
  final Widget Function(BuildContext context, Widget child)? wrapPane;

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
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _close() => Navigator.of(context).pop();

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
    final compact = window.width < kSettingsDialogCompactBelow.width ||
        window.height < kSettingsDialogCompactBelow.height;
    final inset = compact ? 0.0 : kSettingsDialogInset;
    final size = Size(
      (window.width - inset * 2).clamp(0, kSettingsDialogSize.width),
      (window.height - inset * 2).clamp(0, kSettingsDialogSize.height),
    );
    final selected = widget.controller.value;

    return SettingsDialogScope(
      close: _close,
      select: (c) => widget.controller.value = c,
      paneNavigator: (c) => _navigators[c]!.currentState!,
      child: Dialog(
        insetPadding: EdgeInsets.all(inset),
        backgroundColor: palette.background,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(compact ? 0 : AppTheme.radiusCard),
        ),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _escape,
          },
          child: Focus(
            autofocus: true,
            child: SizedBox.fromSize(
              key: const Key('settings-dialog'),
              size: size,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsDialogSidebar(
                    selected: selected,
                    compact: compact,
                    onSelect: (c) => widget.controller.value = c,
                  ),
                  VerticalDivider(
                      width: 1, thickness: 1, color: palette.divider),
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
      onGenerateInitialRoutes: (_, __) => [
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
    required this.select,
    required this.paneNavigator,
    required super.child,
  });

  final VoidCallback close;
  final ValueChanged<SettingsCategory> select;
  final NavigatorState Function(SettingsCategory category) paneNavigator;

  static SettingsDialogScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SettingsDialogScope>();
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
    this.actions = const [],
    required this.child,
  });

  final String title;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 8),
                if (canPop)
                  IconButton(
                    key: const Key('settings-dialog-back'),
                    tooltip: context.l10n.commonBack,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ...actions,
                IconButton(
                  key: const Key('settings-dialog-close'),
                  tooltip: context.l10n.commonClose,
                  icon: const Icon(Icons.close),
                  onPressed: SettingsDialogScope.of(context).close,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
