import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../config/web_config.dart';
import 'settings_providers.dart';

/// The interface language this device uses, or null to follow the device.
/// Synchronous so the first frame has a value: it starts on null and moves
/// to the stored choice once storage answers, like `ThemePresetSetting`.
///
/// In the web player a Mydia instance serves at `/player`, the language of
/// the user who opened it ([hostLocaleProvider]) wins over the stored choice:
/// the browser's storage is shared by everyone who signs in on it, and the
/// player should match the page it was launched from. A choice made in the
/// player's settings still applies for the rest of the session.
class LocaleSetting extends Notifier<Locale?> {
  /// Set by [set], so a stored read finishing later cannot undo a choice.
  bool _chosen = false;

  /// Tail of the write chain: each write starts after the previous one
  /// finished, so overlapping [set] calls reach storage in call order.
  Future<void> _pendingWrite = Future.value();

  @override
  Locale? build() {
    final host = ref.watch(hostLocaleProvider);
    if (host != null) return host;
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final stored =
          await ref.read(coreSettingsServiceProvider).getLocaleCode();
      if (!ref.mounted || _chosen || stored == null) return;
      state = _supported(stored);
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

  /// The player locale for a web UI Gettext code (`es`, `pt_BR`, `zh_Hans`):
  /// the exact language when the player ships it, else the same language
  /// without its region or script, else English. English rather than the
  /// device language, because that is what the web UI shows for a message
  /// nobody translated. Null only for no code at all.
  static Locale? fromHostCode(String? code) {
    if (code == null || code.isEmpty) return null;
    final tag = code.replaceAll('_', '-');
    final exact = _supported(tag);
    if (exact != null) return exact;
    final language = tag.split('-').first;
    for (final l in AppLocalizations.supportedLocales) {
      if (l.languageCode == language &&
          l.countryCode == null &&
          l.scriptCode == null) {
        return l;
      }
    }
    return const Locale('en');
  }

  /// Applies at once; a failed write keeps the choice for this session and
  /// is only logged. Writes are serialized (see [_pendingWrite]) and a failed
  /// one does not block later ones.
  Future<void> set(Locale? locale) {
    _chosen = true;
    state = locale;
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

/// The interface language of the Mydia user who opened the web player, from
/// the `window.mydiaConfig` the instance injects. Null on native, on the
/// public web build, and from an instance too old to send it.
final hostLocaleProvider = Provider<Locale?>(
    (ref) => LocaleSetting.fromHostCode(getWebConfig()?.locale));

/// Hand-written rather than `@Riverpod`: riverpod_generator cannot print
/// `dart:ui`'s `Locale` under build_runner (InvalidTypeException). A plain
/// [NotifierProvider] is kept alive for the app's lifetime.
final localeSettingProvider =
    NotifierProvider<LocaleSetting, Locale?>(LocaleSetting.new);
