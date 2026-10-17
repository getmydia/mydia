/// Opening settings: a dialog over the shell on desktop, the settings routes
/// everywhere else.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/player/platform_features.dart';
import '../settings_nav.dart';
import 'settings_dialog.dart';
import 'settings_panes.dart';

/// Whether settings opens as a dialog. A provider rather than a direct
/// platform check so widget tests, which always run on the host OS, can pick.
final settingsDialogEnabledProvider =
    Provider<bool>((ref) => PlatformFeatures.isDesktop);

/// The open dialog's controller, so a second open retargets it.
SettingsDialogController? _open;

/// A test that ends with the dialog still open never sees `showDialog`
/// complete, so this clears what that left behind.
@visibleForTesting
void resetSettingsDialogForTest() => _open = null;

/// The shell's context while it is mounted. Settings opens only over the
/// shell, never over sign-in or add-a-server.
BuildContext? _host;

void attachSettingsHost(BuildContext context) => _host = context;

void detachSettingsHost(BuildContext context) {
  if (identical(_host, context)) _host = null;
}

/// Whether a settings dialog is up.
bool get isSettingsDialogOpen => _open != null;

/// The host the menu or shortcut may open settings from: the shell, while its
/// route is the top one (root routes such as add-a-server, unlock and the
/// player are pushed over a shell that stays mounted), or while the dialog
/// itself is the top thing, so the menu can retarget it.
BuildContext? _openableHost() {
  final host = _host;
  if (host == null || !host.mounted) return null;
  if (_open != null || ModalRoute.of(host)?.isCurrent == true) return host;
  return null;
}

/// For callers with no widget context of their own: the macOS menu and the
/// Ctrl+, shortcut. False when the shell is not the top route, or not up, or
/// the dialog is off.
bool openSettingsFromHost(String route) {
  final host = _openableHost();
  return host != null && openSettingsForRoute(host, route);
}

/// The macOS menu's navigate command. On desktop the dialog owns the
/// settings routes: one the shell cannot open right now (a full-window flow
/// is in front) is dropped rather than routed, so it never replaces that flow.
void routeMenuNavigation(
  String route, {
  required bool dialogEnabled,
  required void Function(String route) go,
}) {
  if (openSettingsFromHost(route)) return;
  if (dialogEnabled && _categoryFor(route) != null) return;
  go(route);
}

/// Ctrl+, on desktop: opens settings, and leaves an open dialog alone.
bool openSettingsFromShortcut() =>
    !isSettingsDialogOpen && openSettingsFromHost('/settings');

SettingsCategory? _categoryFor(String route) => switch (route) {
      '/settings' => SettingsCategory.playback,
      '/settings/diagnostics' => SettingsCategory.diagnostics,
      '/sources/manage' => SettingsCategory.servers,
      _ => null,
    };

/// Opens the dialog in place of [route] when [route] is a settings route and
/// the dialog is on. False means the caller should navigate as usual.
bool openSettingsForRoute(BuildContext context, String route) {
  final category = _categoryFor(route);
  if (category == null) return false;
  if (!ProviderScope.containerOf(context, listen: false)
      .read(settingsDialogEnabledProvider)) {
    return false;
  }
  openSettings(context, initial: category);
  return true;
}

Future<void> openSettings(
  BuildContext context, {
  SettingsCategory initial = SettingsCategory.playback,
}) async {
  final enabled = ProviderScope.containerOf(context, listen: false)
      .read(settingsDialogEnabledProvider);
  if (!enabled) {
    final router = GoRouter.of(context);
    switch (initial) {
      case SettingsCategory.playback || SettingsCategory.about:
        router.go('/settings');
      case SettingsCategory.diagnostics:
        unawaited(router.push<void>('/settings/diagnostics'));
      case SettingsCategory.servers:
        unawaited(router.push<void>('/sources/manage'));
    }
    return;
  }

  final open = _open;
  if (open != null) {
    open.value = initial;
    return;
  }

  final controller = SettingsDialogController(initial);
  final router = GoRouter.of(context);
  _open = controller;
  try {
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(
        controller: controller,
        rootPage: settingsRootPage,
        wrapPane: (context, child) => SettingsNavScope(
          nav: DialogSettingsNav(
            scope: SettingsDialogScope.of(context),
            router: router,
          ),
          child: child,
        ),
      ),
    );
  } finally {
    if (identical(_open, controller)) _open = null;
    controller.dispose();
  }
}

/// Ctrl+, on Linux and Windows. macOS gets Cmd+, from its menu bar.
bool isSettingsShortcut(
  KeyEvent event, {
  required bool controlPressed,
  bool altPressed = false,
  bool shiftPressed = false,
  bool metaPressed = false,
}) =>
    event is KeyDownEvent &&
    event.logicalKey == LogicalKeyboardKey.comma &&
    controlPressed &&
    !altPressed &&
    !shiftPressed &&
    !metaPressed;
