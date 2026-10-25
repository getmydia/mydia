import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/widgets.dart' show basicLocaleListResolution;

import 'gen/app_localizations.dart';

/// The language the viewer picked in Settings, mirrored here by
/// `LocaleSetting` so code with no `BuildContext` can word what it must show:
/// a system notification, an OS prompt. Null follows the device.
Locale? _chosenLocale;

/// Called by `LocaleSetting` whenever the choice changes or is loaded.
void rememberInterfaceLocale(Locale? locale) => _chosenLocale = locale;

/// The messages in the language the app is showing now, for the few places
/// that have no `BuildContext`. Widgets use `context.l10n` instead: it follows
/// the tree, this does not.
AppLocalizations currentAppLocalizations() {
  final locale = _chosenLocale ??
      basicLocaleListResolution(
        PlatformDispatcher.instance.locales,
        AppLocalizations.supportedLocales,
      );
  return lookupAppLocalizations(locale);
}
