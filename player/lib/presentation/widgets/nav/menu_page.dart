import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../l10n/l10n.dart';
import 'sidebar_content.dart';

/// What the menu shows: the shell's navigation location and whether its
/// source is offline. A record, so an unchanged shell notifies no one.
typedef MenuPageState = ({String location, bool isOffline});

/// The phone navigation in the iOS app: the sidebar's rows as a full page.
///
/// iOS has no navigation drawer, and its left-edge swipe is the system's
/// back gesture, so the shell pushes this page where other phones slide the
/// `MobileDrawer` in (see `AppShell.usesMenuPage`). It is pushed on the root
/// navigator, so it covers the shell like any page: the native tab bar and
/// the cast accessory hide under it as they do under the player.
class MenuPage extends StatelessWidget {
  const MenuPage({
    super.key,
    required this.state,
    required this.onNavigate,
    required this.onSwitchSource,
  });

  /// The shell's state, followed while the page is open: a server switch
  /// navigates the shell underneath and the rows follow it.
  final ValueListenable<MenuPageState> state;

  /// Navigates the shell. Called after the page has closed.
  final ValueChanged<String> onNavigate;

  /// Navigates the shell to another server, leaving the page open on that
  /// server's rows, as the drawer stays open across a switch.
  final ValueChanged<String> onSwitchSource;

  /// Pushes the page over the shell. [ref] is the shell's: when the page
  /// closes, sidebar edit mode ends, which `AppShell.onDrawerVisibilityChanged`
  /// does for the drawer.
  static Future<void> open(
    BuildContext context, {
    required WidgetRef ref,
    required ValueListenable<MenuPageState> state,
    required ValueChanged<String> onNavigate,
    required ValueChanged<String> onSwitchSource,
  }) async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'menu'),
        builder: (_) => MenuPage(
          state: state,
          onNavigate: onNavigate,
          onSwitchSource: onSwitchSource,
        ),
      ),
    );
    if (context.mounted) ref.read(sidebarEditModeProvider.notifier).exit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.commonMenu)),
      body: SafeArea(
        top: false,
        child: ValueListenableBuilder<MenuPageState>(
          valueListenable: state,
          builder: (context, value, _) => SidebarContent(
            location: value.location,
            isOffline: value.isOffline,
            onNavigate: (route) {
              Navigator.of(context).pop();
              onNavigate(route);
            },
            onSwitchSource: onSwitchSource,
          ),
        ),
      ),
    );
  }
}

/// Puts the shell's menu page within reach of the screens it hosts, for
/// `AppShell.openNavigation`. Only the shell that uses the page provides one.
class ShellMenuScope extends InheritedWidget {
  const ShellMenuScope({super.key, required this.open, required super.child});

  /// Pushes the menu page.
  final VoidCallback open;

  static ShellMenuScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ShellMenuScope>();

  @override
  bool updateShouldNotify(ShellMenuScope oldWidget) => false;
}
