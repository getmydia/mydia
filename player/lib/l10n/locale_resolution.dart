import 'dart:ui';

import 'package:flutter/widgets.dart' show basicLocaleListResolution;

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
/// `MaterialApp.localeListResolutionCallback`. This is Flutter's own
/// [basicLocaleListResolution] run over [supported] without its stubs, so the
/// ordering rules are unchanged: a bare `pt` or `pt_PT` device finds the
/// regional `pt_BR` as its language match, and anything unmatched falls to
/// English.
Locale resolveLocaleList(
  List<Locale>? device,
  Iterable<Locale> supported, {
  Set<String> stubs = stubLanguageCodes,
}) {
  final usable = [
    for (final l in supported)
      if (!isStubLocale(l, stubs: stubs)) l,
  ];
  if (usable.isEmpty) return const Locale('en');
  // basicLocaleListResolution falls back to the first supported locale, so
  // put English there.
  final english = usable.where((l) => l.languageCode == 'en');
  final ordered = [...english, ...usable.where((l) => !english.contains(l))];
  return basicLocaleListResolution(device, ordered);
}

/// `MaterialApp.localeListResolutionCallback` for the generated locales.
Locale resolveAppLocale(List<Locale>? device, Iterable<Locale> supported) =>
    resolveLocaleList(device, supported);
