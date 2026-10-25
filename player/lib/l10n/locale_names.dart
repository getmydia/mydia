import 'package:flutter/widgets.dart';

/// Each language's name in that language, as the language picker lists it.
/// Not translated: a reader looks for their own language by its own name.
const Map<String, String> _names = {
  'en': 'English',
  'es': 'Español',
};

/// The picker label for [locale]; falls back to the language code for a
/// locale added to the ARB files before this map.
String localeDisplayName(Locale locale) =>
    _names[locale.languageCode] ?? locale.toLanguageTag();
