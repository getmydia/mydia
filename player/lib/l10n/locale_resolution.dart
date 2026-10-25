import 'dart:ui';

import 'gen/app_localizations.dart';

/// Languages whose base ARB (`app_<code>.arb`) holds no messages. A stub
/// exists only because gen_l10n needs a base file next to a regional one
/// (`app_pt.arb` for `app_pt_BR.arb`), so choosing it would show English.
/// Stubs are hidden from the language picker, never stored or returned as a
/// host language, and a device locale in that language resolves to the
/// regional variant the player ships instead (pt, pt_PT -> pt_BR).
///
/// `test/l10n/locale_resolution_test.dart` checks that each listed ARB holds
/// only `@@locale` and that no other base ARB is empty.
const Set<String> stubLanguageCodes = {'pt'};

/// Whether [locale] is a bare stub language such as `pt`.
bool isStubLocale(Locale locale, {Set<String> stubs = stubLanguageCodes}) =>
    locale.countryCode == null &&
    locale.scriptCode == null &&
    stubs.contains(locale.languageCode);

/// The shipped locales a viewer can choose: everything but the stubs.
List<Locale> get pickableLocales => [
      for (final l in AppLocalizations.supportedLocales)
        if (!isStubLocale(l)) l,
    ];

/// Picks the shipped locale for the device's preferred [device] locales, for
/// `MaterialApp.localeListResolutionCallback`. Exact match first (across the
/// whole list, stubs excluded), then the same language, preferring a
/// non-stub (a bare, then any regional one), else English.
Locale resolveLocaleList(
  List<Locale>? device,
  Iterable<Locale> supported, {
  Set<String> stubs = stubLanguageCodes,
}) {
  final usable = [
    for (final l in supported)
      if (!isStubLocale(l, stubs: stubs)) l,
  ];
  final wanted = device ?? const <Locale>[];

  for (final d in wanted) {
    for (final l in usable) {
      if (l.languageCode == d.languageCode &&
          l.scriptCode == d.scriptCode &&
          l.countryCode == d.countryCode) {
        return l;
      }
    }
  }
  for (final d in wanted) {
    Locale? bare;
    Locale? regional;
    for (final l in usable) {
      if (l.languageCode != d.languageCode) continue;
      if (l.countryCode == null && l.scriptCode == null) {
        bare ??= l;
      } else {
        regional ??= l;
      }
    }
    final match = bare ?? regional;
    if (match != null) return match;
  }
  return const Locale('en');
}

/// `MaterialApp.localeListResolutionCallback` for the generated locales.
Locale resolveAppLocale(List<Locale>? device, Iterable<Locale> supported) =>
    resolveLocaleList(device, supported);
