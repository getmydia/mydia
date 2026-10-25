import 'package:flutter/widgets.dart';

import 'gen/app_localizations.dart';

export 'current_l10n.dart';
export 'formatters.dart';
export 'gen/app_localizations.dart';

/// `context.l10n.someKey` instead of `AppLocalizations.of(context).someKey`.
extension L10n on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
