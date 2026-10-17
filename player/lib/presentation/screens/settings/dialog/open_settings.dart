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

/// For callers with no widget context of their own: the macOS menu and the
/// Ctrl+, shortcut. False when the shell is not up or the dialog is off.
bool openSettingsFromHost(String route) {
  final host = _host;
  if (host == null || !host.mounted) return false;
  return openSettingsForRoute(host, route);
}

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
bool isSettingsShortcut(KeyEvent event, {required bool controlPressed}) =>
    event is KeyDownEvent &&
    event.logicalKey == LogicalKeyboardKey.comma &&
    controlPressed;
