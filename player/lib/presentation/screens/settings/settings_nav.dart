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

  void openPairedDevices();

  /// The Servers & devices hub.
  void openConnections();

  /// One account's detail page.
  void openAccount(String accountId);

  /// The account on screen was just removed from this device.
  void accountRemoved();

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

  @override
  void openPairedDevices() => _router.push('/sources/manage?section=devices');

  @override
  void openConnections() => _router.push('/sources/manage');

  @override
  void openAccount(String accountId) =>
      _router.push('/sources/manage/account/$accountId');

  /// Steps back to the hub, and only while the router is still on the
  /// account detail page: removal may already have sent it elsewhere. A
  /// page loaded directly has nothing to pop, so it goes to the hub.
  @override
  void accountRemoved() {
    if (!_topPath.startsWith('/sources/manage/account/')) return;
    if (_router.canPop()) {
      _router.pop();
    } else {
      _router.go('/sources/manage');
    }
  }

  /// Removing the last or current source can already have sent the router
  /// elsewhere (add-a-server); only step back if still on the instance.
  @override
  void instanceRemoved() {
    if (_topPath.startsWith('/sources/manage/')) _router.go('/sources/manage');
  }

  /// The top page's path. `currentConfiguration.uri` stays on the base
  /// location under a pushed page, so it never shows a pushed account.
  String get _topPath => _router.state.uri.path;

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
