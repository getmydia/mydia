import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/sources/sign_in_problem.dart';

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    test('every sign-in issue has text in $locale', () {
      final l10n = lookupAppLocalizations(locale);
      for (final issue in SignInIssue.values) {
        expect(
          l10n.signInProblemText(SignInProblem(issue)),
          isNotEmpty,
          reason: issue.name,
        );
      }
    });
  }

  test('a server message is shown as the server wrote it', () {
    final es = lookupAppLocalizations(const Locale('es'));
    expect(
      es.signInProblemText(const SignInProblem.fromServer('Bad token')),
      'Bad token',
    );
  });

  test('an app issue follows the viewer language', () {
    final es = lookupAppLocalizations(const Locale('es'));
    final en = lookupAppLocalizations(const Locale('en'));
    const problem = SignInProblem(SignInIssue.jellyfinWrongCredentials);
    expect(en.signInProblemText(problem), 'Wrong username or password.');
    expect(es.signInProblemText(problem), isNot(en.signInProblemText(problem)));
  });

  test('the remove-account body counts downloads in each language', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(
      en.sourcesRemoveAccountBodyWithDownloads('Ana', 1, '1.0 GB'),
      contains('1 download (1.0 GB)'),
    );
    expect(
      en.sourcesRemoveAccountBodyWithDownloads('Ana', 3, '2.0 GB'),
      contains('3 downloads (2.0 GB)'),
    );
  });
}
