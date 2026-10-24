import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'untranslated_text_scanner.dart';

/// Converted to `context.l10n`. Literal English added under these paths
/// fails here; converting a screen means adding its path. See
/// docs/l10n.md.
const convertedPaths = <String>[
  'lib/presentation/screens/settings',
  'lib/presentation/widgets/language_picker.dart',
];

void main() {
  test('converted code has no literal English', () {
    final found = <UntranslatedLiteral>[];
    for (final path in convertedPaths) {
      final entity = FileSystemEntity.typeSync(path);
      expect(entity, isNot(FileSystemEntityType.notFound), reason: path);
      final files = entity == FileSystemEntityType.directory
          ? Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
          : [File(path)];
      for (final f in files) {
        found.addAll(findUntranslated(f.readAsStringSync(), path: f.path));
      }
    }
    expect(
      found,
      isEmpty,
      reason: 'Move these strings to lib/l10n/app_en.arb:\n${found.join('\n')}',
    );
  });
}
