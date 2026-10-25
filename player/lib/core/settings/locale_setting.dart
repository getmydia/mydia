import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import 'settings_providers.dart';

/// The interface language this device uses, or null to follow the device.
/// Synchronous so the first frame has a value: it starts on null and moves
/// to the stored choice once storage answers, like `ThemePresetSetting`.
class LocaleSetting extends Notifier<Locale?> {
  /// Set by [set], so a stored read finishing later cannot undo a choice.
  bool _chosen = false;

  /// Tail of the write chain: each write starts after the previous one
  /// finished, so overlapping [set] calls reach storage in call order.
  Future<void> _pendingWrite = Future.value();

  @override
  Locale? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final stored =
          await ref.read(coreSettingsServiceProvider).getLocaleCode();
      if (!ref.mounted || _chosen || stored == null) return;
      state = _supported(stored);
      rememberInterfaceLocale(state);
    } catch (e) {
      debugPrint('[LocaleSetting] Could not load: $e');
    }
  }

  /// A stored tag the app still ships, or null. A language dropped from the
  /// ARB files falls back to the device language instead of English.
  static Locale? _supported(String tag) {
    for (final l in AppLocalizations.supportedLocales) {
      if (l.toLanguageTag() == tag) return l;
    }
    return null;
  }

  /// Applies at once; a failed write keeps the choice for this session and
  /// is only logged. Writes are serialized (see [_pendingWrite]) and a failed
  /// one does not block later ones.
  Future<void> set(Locale? locale) {
    _chosen = true;
    state = locale;
    rememberInterfaceLocale(locale);
    final service = ref.read(coreSettingsServiceProvider);
    return _pendingWrite = _pendingWrite.then((_) async {
      try {
        await service.setLocaleCode(locale?.toLanguageTag());
      } catch (e) {
        debugPrint('[LocaleSetting] Could not persist: $e');
      }
    });
  }
}

/// Hand-written rather than `@Riverpod`: riverpod_generator cannot print
/// `dart:ui`'s `Locale` under build_runner (InvalidTypeException). A plain
/// [NotifierProvider] is kept alive for the app's lifetime.
final localeSettingProvider =
    NotifierProvider<LocaleSetting, Locale?>(LocaleSetting.new);
