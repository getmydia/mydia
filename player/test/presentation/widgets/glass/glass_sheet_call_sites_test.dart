import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// In-app sheets go through showGlassSheet. These stay as they are: the
/// helper itself, the OSD sheet helper, and sheets opened from the player.
const _allowed = {
  'lib/presentation/widgets/glass/glass_sheet.dart',
  'lib/presentation/widgets/osd_sheet.dart',
  'lib/presentation/widgets/quality_selector.dart',
};

void main() {
  test('no showModalBottomSheet call outside showGlassSheet', () {
    final offenders = <String>[];
    final call = RegExp(r'\bshowModalBottomSheet<');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_allowed.contains(path)) continue;
      if (call.hasMatch(entity.readAsStringSync())) offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: 'Use showGlassSheet (lib/presentation/widgets/glass/).');
  });
}
