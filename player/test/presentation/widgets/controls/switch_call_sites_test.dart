import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every switch goes through AppSwitch (or AppSwitchTile for a list row), so
/// Frosted gets the compact control.
const _allowed = {'lib/presentation/widgets/controls/app_switch.dart'};

/// The playback OSD is outside the Frosted restyle; its stats toggle keeps
/// the stock row. Only the list-tile check skips it.
const _tileAllowed = {'lib/presentation/widgets/hls_quality_selector.dart'};

void main() {
  test('no Switch( is built outside AppSwitch', () {
    expect(
      _offenders(
        RegExp(r'\bSwitch\(|\bSwitch\.adaptive\b|\bCupertinoSwitch\b'),
      ),
      isEmpty,
      reason: 'Use AppSwitch (lib/presentation/widgets/controls/).',
    );
  });

  test('no SwitchListTile is built outside AppSwitchTile', () {
    expect(
      _offenders(RegExp(r'\bSwitchListTile\b'), extra: _tileAllowed),
      isEmpty,
      reason: 'Use AppSwitchTile (lib/presentation/widgets/controls/).',
    );
  });
}

List<String> _offenders(RegExp pattern, {Set<String> extra = const {}}) {
  final offenders = <String>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    if (_allowed.contains(path) ||
        extra.contains(path) ||
        path.endsWith('.g.dart')) {
      continue;
    }
    final code = entity
        .readAsLinesSync()
        .map((line) => line.replaceFirst(RegExp(r'//.*'), ''))
        .join('\n');
    if (pattern.hasMatch(code)) offenders.add(path);
  }
  return offenders;
}
