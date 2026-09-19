// Every transient message goes through `Toaster`
// (lib/presentation/widgets/toast/). A stock SnackBar renders in the shell's
// root Scaffold: centred under the desktop sidebar, over the cast bar and the
// playback controls, in whatever colour its call site picked. This keeps one
// from creeping back in by copy-paste.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _snackBar = RegExp(
  r'\b(SnackBar\w*|showSnackBar|ScaffoldMessenger\w*|snackBarTheme)\b',
);

bool _isSource(File file) =>
    file.path.endsWith('.dart') &&
    !file.path.endsWith('.g.dart') &&
    !file.path.endsWith('.graphql.dart') &&
    !file.path.endsWith('.freezed.dart');

void main() {
  test('lib/ shows no SnackBars', () {
    final offenders = <String>[];
    final files = Directory('lib').listSync(recursive: true).whereType<File>();
    for (final file in files.where(_isSource)) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        // Comments may still name the old pattern when explaining history.
        if (line.startsWith('//')) continue;
        if (_snackBar.hasMatch(line)) {
          offenders.add('${file.path}:${i + 1}: $line');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Use Toaster.of(context).show(...) or showToast(...):\n'
          '${offenders.join('\n')}',
    );
  });
}
