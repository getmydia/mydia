import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// D-Bus names, kept together so a typo is visible in one place.
const _portalName = 'org.freedesktop.portal.Desktop';
const _portalPath = '/org/freedesktop/portal/desktop';
const _settingsInterface = 'org.freedesktop.portal.Settings';
const _appearance = 'org.freedesktop.appearance';
const _accentKey = 'accent-color';

/// One `SettingChanged` signal from the Settings portal.
typedef PortalSettingChange = ({
  String namespace,
  String key,
  DBusValue value,
});

/// The slice of `org.freedesktop.portal.Settings` the theme needs. A seam so
/// tests can script the portal without a session bus.
abstract interface class PortalSettingsClient {
  /// `ReadOne`, portal version 2 and later.
  Future<DBusValue> readOne(String namespace, String key);

  /// The deprecated `Read`, whose value arrives wrapped in two variants.
  Future<DBusValue> read(String namespace, String key);

  Stream<PortalSettingChange> get changes;

  Future<void> close();
}

class DBusPortalSettingsClient implements PortalSettingsClient {
  DBusPortalSettingsClient({DBusClient? client})
      : _client = client ?? DBusClient.session() {
    _portal = DBusRemoteObject(
      _client,
      name: _portalName,
      path: DBusObjectPath(_portalPath),
    );
  }

  final DBusClient _client;
  late final DBusRemoteObject _portal;

  Future<DBusValue> _call(String method, String namespace, String key) async {
    final reply = await _portal.callMethod(
      _settingsInterface,
      method,
      [DBusString(namespace), DBusString(key)],
      replySignature: DBusSignature('v'),
    );
    return reply.returnValues[0];
  }

  @override
  Future<DBusValue> readOne(String namespace, String key) =>
      _call('ReadOne', namespace, key);

  @override
  Future<DBusValue> read(String namespace, String key) =>
      _call('Read', namespace, key);

  @override
  Stream<PortalSettingChange> get changes => DBusRemoteObjectSignalStream(
        object: _portal,
        interface: _settingsInterface,
        name: 'SettingChanged',
        signature: DBusSignature('ssv'),
      ).map((s) => (
            namespace: s.values[0].asString(),
            key: s.values[1].asString(),
            value: s.values[2],
          ));

  @override
  Future<void> close() => _client.close();
}

/// The session-bus Settings portal client, closed with the container.
final portalSettingsClientProvider = Provider<PortalSettingsClient>((ref) {
  final client = DBusPortalSettingsClient();
  ref.onDispose(client.close);
  return client;
});

/// The portal's `accent-color`: an `(ddd)` sRGB triple in [0, 1], possibly
/// wrapped in variants. Null when unset (any component out of range, per
/// the portal spec) or not that shape.
Color? decodePortalAccent(DBusValue value) {
  var v = value;
  while (v is DBusVariant) {
    v = v.value;
  }
  if (v is! DBusStruct || v.children.length != 3) return null;
  final components = <double>[];
  for (final c in v.children) {
    if (c is! DBusDouble || c.value < 0 || c.value > 1) return null;
    components.add(c.value);
  }
  int byte(double d) => (d * 255).round();
  return Color.fromARGB(
    255,
    byte(components[0]),
    byte(components[1]),
    byte(components[2]),
  );
}

/// The Linux desktop's accent colour, live. Null off native Linux, when the
/// desktop reports none, or when the portal cannot be reached; the palette
/// then uses the desktop's stock accent.
///
/// Hand-written rather than `@riverpod`: riverpod_generator throws
/// `InvalidTypeException` on a notifier whose state type is `Color`.
final linuxAccentProvider = NotifierProvider<LinuxAccent, Color?>(
  LinuxAccent.new,
);

class LinuxAccent extends Notifier<Color?> {
  /// Forces the platform check in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugIsNativeLinux;

  static bool get _isNativeLinux =>
      debugIsNativeLinux ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux);

  /// Set once a signal lands, so the initial read answering later cannot
  /// put back an older accent.
  bool _signalled = false;

  @override
  Color? build() {
    _signalled = false;
    if (!_isNativeLinux) return null;
    final PortalSettingsClient client;
    try {
      client = ref.watch(portalSettingsClientProvider);
    } catch (e) {
      debugPrint('[LinuxAccent] No session bus: $e');
      return null;
    }
    final sub = client.changes
        .where((c) => c.namespace == _appearance && c.key == _accentKey)
        .listen(
      (c) {
        _signalled = true;
        state = decodePortalAccent(c.value);
      },
      onError: (Object e) => debugPrint('[LinuxAccent] Signal failed: $e'),
    );
    ref.onDispose(sub.cancel);
    unawaited(_initialRead(client));
    return null;
  }

  Future<void> _initialRead(PortalSettingsClient client) async {
    try {
      DBusValue value;
      try {
        value = await client.readOne(_appearance, _accentKey);
      } on DBusUnknownMethodException {
        value = await client.read(_appearance, _accentKey);
      }
      if (!ref.mounted || _signalled) return;
      state = decodePortalAccent(value);
    } catch (e) {
      debugPrint('[LinuxAccent] Could not read the accent: $e');
    }
  }
}
