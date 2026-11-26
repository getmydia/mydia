import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// OSD pills are only rated for white glyphs: their dry tint
/// (`osdDryTintOpacity`) and their sampled control tokens clear 4.5:1 for
/// white but not 3:1 for `textSecondary`. Anything in the video controls that
/// draws secondary or tertiary text must sit on a panel
/// (`GlassSurface.osd`), whose tokens are rated for it.
void main() {
  test('video_controls never draw textSecondary or textTertiary', () {
    final offenders = <String>[];
    for (final entity in Directory(
      'lib/presentation/widgets/video_controls',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final code = entity
          .readAsLinesSync()
          .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
          .join('\n');
      if (RegExp(r'textSecondary|textTertiary').hasMatch(code)) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Pills are rated for white glyphs only; see this test.',
    );
  });
}
