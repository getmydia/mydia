import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'gen/app_localizations.dart';
import 'gen/app_localizations_cnr.dart';

/// Languages the player ships that Flutter's own localizations and `intl`
/// have no data for, each mapped to the closest locale they do have.
///
/// Montenegrin (`cnr`) borrows Serbian in Latin script: the same plural rules,
/// month and weekday names, and number symbols. Without an alias the Material
/// widgets find no `MaterialLocalizations` and `intl` throws on the first
/// date, number or plural.
const Map<String, Locale> formattingAliases = {
  'cnr': Locale.fromSubtags(languageCode: 'sr', scriptCode: 'Latn'),
};

/// Builds the messages for an aliased language, with `localeName` set to the
/// alias so every `intl` call made with it finds data.
final Map<String, AppLocalizations Function(String)> _aliasedMessages = {
  'cnr': AppLocalizationsCnr.new,
};

/// The messages for [locale]. Use this instead of `lookupAppLocalizations`.
AppLocalizations appLocalizationsFor(Locale locale) {
  final alias = formattingAliases[locale.languageCode];
  final build = _aliasedMessages[locale.languageCode];
  if (alias == null || build == null) return lookupAppLocalizations(locale);
  return build(alias.toString());
}

/// Every `MaterialApp`'s `localizationsDelegates`: the generated ones, with
/// the aliased languages served by the Flutter data of their alias.
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  _AppMessagesDelegate(),
  _AliasDelegate<MaterialLocalizations>(GlobalMaterialLocalizations.delegate),
  _AliasDelegate<CupertinoLocalizations>(GlobalCupertinoLocalizations.delegate),
  _AliasDelegate<WidgetsLocalizations>(GlobalWidgetsLocalizations.delegate),
  ...AppLocalizations.localizationsDelegates,
];

class _AppMessagesDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _AppMessagesDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLocalizations.delegate.isSupported(locale);

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(appLocalizationsFor(locale));

  @override
  bool shouldReload(_AppMessagesDelegate old) => false;
}

/// Loads [inner]'s localizations for the alias of an aliased language. A
/// `Localizations` widget takes the first delegate of each type that supports
/// the locale, so this, listed before [inner], answers only for aliases.
class _AliasDelegate<T> extends LocalizationsDelegate<T> {
  const _AliasDelegate(this.inner);

  final LocalizationsDelegate<T> inner;

  @override
  bool isSupported(Locale locale) =>
      formattingAliases.containsKey(locale.languageCode);

  @override
  Future<T> load(Locale locale) =>
      inner.load(formattingAliases[locale.languageCode] ?? locale);

  @override
  bool shouldReload(_AliasDelegate<T> old) => false;
}
