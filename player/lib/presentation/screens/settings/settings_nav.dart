/// Where a settings row goes when it leads somewhere.
///
/// The same bodies render on the mobile routes and inside the desktop
/// settings dialog. On mobile a row pushes a route; in the dialog it pushes
/// onto the dialog's own navigator, or closes the dialog first when the
/// destination needs the whole window. Bodies ask this rather than the router
/// so neither host has to know about the other.
library;

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/source.dart';
import '../detail/detail_links.dart';

abstract interface class SettingsNav {
  /// One Mydia instance's settings.
  void openInstance(SourceId id);

  void openDiagnostics();

  /// The instance on screen was just removed from this device.
  void instanceRemoved();

  void addServer();

  /// Sign in again, or change a connection's address or servers.
  void reauth(SourceKind kind, String accountId);

  /// A Plex Home user switch landed on [id].
  void switchedTo(SourceId id);
}

/// The routes the screens used before the dialog existed.
class RouterSettingsNav implements SettingsNav {
  const RouterSettingsNav(this._router);

  final GoRouter _router;

  @override
  void openInstance(SourceId id) => _router.push('/sources/manage/${id.value}');

  @override
  void openDiagnostics() => _router.push('/settings/diagnostics');

  /// Removing the last or current source can already have sent the router
  /// elsewhere (add-a-server); only step back if still on the instance.
  @override
  void instanceRemoved() {
    final path = _router.routerDelegate.currentConfiguration.uri.path;
    if (path.startsWith('/sources/manage/')) _router.go('/sources/manage');
  }

  @override
  void addServer() => _router.push('/sources/add');

  @override
  void reauth(SourceKind kind, String accountId) =>
      _router.push('/sources/add/${kind.name}?account=$accountId');

  @override
  void switchedTo(SourceId id) => _router.go(sourceHomeLocation(id));
}

class SettingsNavScope extends InheritedWidget {
  const SettingsNavScope({super.key, required this.nav, required super.child});

  final SettingsNav nav;

  /// The enclosing dialog's nav, or the router's when there is none.
  static SettingsNav of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsNavScope>()?.nav ??
      RouterSettingsNav(GoRouter.of(context));

  @override
  bool updateShouldNotify(SettingsNavScope oldWidget) => nav != oldWidget.nav;
}
