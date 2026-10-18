import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every in-app dialog goes through GlassDialog, so iOS and macOS get glass.
/// The one exception is opened from the player screen and stays as it is.
const _allowed = {
  'lib/presentation/widgets/glass/glass_dialog.dart',
  'lib/presentation/widgets/resume_dialog.dart',
};

void main() {
  test('no AlertDialog is built outside GlassDialog', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_allowed.contains(path) || path.endsWith('.g.dart')) continue;
      final code = entity
          .readAsLinesSync()
          .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
          .join('\n');
      if (RegExp(r'\bAlertDialog\(').hasMatch(code)) offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: 'Use GlassDialog (lib/presentation/widgets/glass/).');
  });
}
