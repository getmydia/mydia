import 'package:flutter/widgets.dart';

import 'gen/app_localizations.dart';

export 'formatters.dart';
export 'gen/app_localizations.dart';
export 'locale_resolution.dart';

/// `context.l10n.someKey` instead of `AppLocalizations.of(context).someKey`.
extension L10n on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
