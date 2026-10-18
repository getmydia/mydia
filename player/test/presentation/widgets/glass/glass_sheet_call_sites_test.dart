import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// In-app sheets go through showGlassSheet. These stay as they are: the
/// helper itself, the OSD sheet helper, and sheets opened from the player.
const _allowed = {
  'lib/presentation/widgets/glass/glass_sheet.dart',
  'lib/presentation/widgets/osd_sheet.dart',
  'lib/presentation/widgets/quality_selector.dart',
};

final _call = RegExp(r'\bshowModalBottomSheet\s*(<|\()');

/// Whether [source] calls showModalBottomSheet, typed or not, outside
/// `//` and `///` comments.
bool callsShowModalBottomSheet(String source) => source
    .split('\n')
    .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
    .any(_call.hasMatch);

void main() {
  test('no showModalBottomSheet call outside showGlassSheet', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_allowed.contains(path)) continue;
      if (callsShowModalBottomSheet(entity.readAsStringSync())) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'Use showGlassSheet (lib/presentation/widgets/glass/).');
  });

  test('the matcher catches typed and untyped calls, not comments', () {
    expect(callsShowModalBottomSheet('showModalBottomSheet<int>('), isTrue);
    expect(
        callsShowModalBottomSheet('  await showModalBottomSheet(\n'), isTrue);
    expect(callsShowModalBottomSheet('showModalBottomSheet (context:'), isTrue);
    expect(callsShowModalBottomSheet('// showModalBottomSheet(x)'), isFalse);
    expect(
        callsShowModalBottomSheet('/// see showModalBottomSheet<T>'), isFalse);
    expect(callsShowModalBottomSheet('final x = 1; // showModalBottomSheet('),
        isFalse);
  });
}
