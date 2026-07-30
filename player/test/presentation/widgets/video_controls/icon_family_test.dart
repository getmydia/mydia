// Playback chrome must draw every glyph from a single Material icon family.
//
// Four families had drifted into this feature — `_outlined` (stroke),
// `_rounded` (filled, round terminals), and bare/sharp (filled, square
// terminals), with `volume_up` and `volume_up_rounded` both in use. Mixing
// fills and stroke weights in one control row is the defect this guards.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files that make up the playback chrome.
const _chromePaths = <String>[
  'lib/presentation/widgets/video_controls',
  'lib/presentation/widgets/gesture_controls.dart',
  'lib/presentation/widgets/up_next_overlay.dart',
];

/// `Icons.foo` / `Icons.foo_bar_10` references.
final _iconRef = RegExp(r'\bIcons\.([a-z0-9_]+)');

List<File> _dartFiles() {
  final files = <File>[];
  for (final path in _chromePaths) {
    final entity = FileSystemEntity.typeSync(path);
    if (entity == FileSystemEntityType.directory) {
      files.addAll(
        Directory(path)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
      );
    } else if (entity == FileSystemEntityType.file) {
      files.add(File(path));
    }
  }
  return files;
}

void main() {
  test('every icon in playback chrome is from the _rounded family', () {
    final offenders = <String>[];

    for (final file in _dartFiles()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final match in _iconRef.allMatches(lines[i])) {
          final name = match.group(1)!;
          if (!name.endsWith('_rounded')) {
            offenders.add('${file.path}:${i + 1}  Icons.$name');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Playback chrome must use only Icons.*_rounded. Found:\n'
          '${offenders.join('\n')}',
    );
  });

  test('the scan actually finds source files (guards against a silent pass)',
      () {
    expect(_dartFiles(), isNotEmpty);
  });
}
