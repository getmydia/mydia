import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every switch goes through AppSwitch, so Frosted gets the compact control.
const _allowed = {'lib/presentation/widgets/controls/app_switch.dart'};

void main() {
  test('no Switch( is built outside AppSwitch', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_allowed.contains(path) || path.endsWith('.g.dart')) continue;
      final code = entity
          .readAsLinesSync()
          .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
          .join('\n');
      if (RegExp(r'\bSwitch\(').hasMatch(code)) offenders.add(path);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Use AppSwitch (lib/presentation/widgets/controls/).',
    );
  });
}
