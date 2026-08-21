import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

const _controllableKey = 'remote_control_controllable';

/// Hive box name for this device's remote-control preferences.
const _boxName = 'remote_control_settings';

/// Whether this device advertises itself as controllable.
///
/// Being a target means keeping an iroh endpoint and a relay connection up for
/// as long as the app runs, which costs battery and radio on a phone. Defaults
/// on so a freshly paired device appears in the picker without anyone hunting
/// for a setting, and stays off once someone turns it off.
class RemoteControlSettings {
  final Box<dynamic> _box;

  RemoteControlSettings({required Box<dynamic> box}) : _box = box;

  Future<bool> controllableEnabled() async {
    final stored = _box.get(_controllableKey);
    // No explicit choice yet. Every platform defaults on: an invisible device
    // with no explanation is worse than an idle endpoint.
    return stored is bool ? stored : true;
  }

  Future<void> setControllable(bool value) async =>
      _box.put(_controllableKey, value);
}

/// Opens this device's remote-control settings box once and reuses it,
/// closing it when the provider itself is torn down. Matches
/// `castSessionStoreProvider` (`core/cast/cast_providers.dart`).
final remoteControlSettingsProvider =
    FutureProvider<RemoteControlSettings>((ref) async {
  final box = await Hive.openBox<dynamic>(_boxName);
  ref.onDispose(() => unawaited(box.close()));
  return RemoteControlSettings(box: box);
});

/// Whether this device currently advertises itself as controllable.
///
/// Derived from [remoteControlSettingsProvider] rather than read once, so the
/// settings screen's switch can `watch` it and pick up
/// [RemoteControlSettings.setControllable] after the caller invalidates this
/// provider.
final remoteControlEnabledProvider = FutureProvider<bool>((ref) async {
  final settings = await ref.watch(remoteControlSettingsProvider.future);
  return settings.controllableEnabled();
});
