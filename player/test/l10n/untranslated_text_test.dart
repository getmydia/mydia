import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'untranslated_text_scanner.dart';

/// Generated code, which nobody writes by hand. `lib/graphql/` holds only
/// graphql_codegen output and its export file.
const excludedPaths = <String>['lib/l10n/gen/', 'lib/graphql/'];
const excludedSuffixes = <String>['.g.dart', '.freezed.dart', '.gql.dart'];

/// Everything under `lib/` is checked. Literal English added anywhere fails
/// here; see docs/l10n.md.
void main() {
  test('lib/ has no literal English', () {
    final found = <UntranslatedLiteral>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !excludedPaths.any(f.path.startsWith))
        .where((f) => !excludedSuffixes.any(f.path.endsWith));
    for (final f in files) {
      found.addAll(findUntranslated(f.readAsStringSync(), path: f.path));
    }
    expect(
      found,
      isEmpty,
      reason: 'Move these strings to lib/l10n/app_en.arb:\n${found.join('\n')}',
    );
  });
}
