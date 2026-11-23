import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every select goes through AppSelect, so both modes get the house field
/// and the themed menu.
const _allowed = {'lib/presentation/widgets/controls/app_select.dart'};

final _dropdown = RegExp(
  r'\b(DropdownButton|DropdownButtonFormField|DropdownMenu|DropdownMenuFormField)\b',
);

void main() {
  test('no DropdownButton outside AppSelect', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (_allowed.contains(path) || path.endsWith('.g.dart')) continue;
      final code = entity
          .readAsLinesSync()
          .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
          .join('\n');
      if (_dropdown.hasMatch(code)) offenders.add(path);
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Use AppSelect (lib/presentation/widgets/controls/).',
    );
  });

  test('the pattern catches each Material dropdown form', () {
    for (final source in [
      'DropdownButton<int>(',
      'DropdownButton(',
      'DropdownButtonFormField<String>(',
      'DropdownMenu<String>(',
      'DropdownMenuFormField<String>(',
    ]) {
      expect(_dropdown.hasMatch(source), isTrue, reason: source);
    }
    for (final source in ['_VersionPickerButton(', 'MyDropdownButtonX(']) {
      expect(_dropdown.hasMatch(source), isFalse, reason: source);
    }
  });
}
