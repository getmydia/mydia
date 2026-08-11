// The bug this guards against spread by copy-paste: eight screens carried the
// identical line `final bottomPadding = isDesktop ? 32.0 : 100.0;`, and the
// dock is 83 to 117 tall depending on the device's home indicator.
//
// Six screens cannot be mounted in a widget test without building their whole
// provider graph, so a render assertion cannot cover them. This can.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Vector 1: the copy-paste that created this bug.
///
/// Deliberately requires the assigned variable's name to contain "bottom".
/// A bare `isDesktop ? N : M` is far too broad: the codebase has nine
/// legitimate ones for title padding, section gaps and rail headers
/// (`filter_screen.dart`, `library_screen.dart`, `home_screen.dart`,
/// `content_rail.dart`). A guard that cries wolf on those is a guard someone
/// deletes.
final RegExp _hardcodedBottomTernary = RegExp(
  r'bottom\w*\s*=\s*isDesktop\s*\?\s*[\d.]+\s*:\s*[\d.]+',
  caseSensitive: false,
);

/// Vector 2: a screen declaring its own dock clearance in prose.
///
/// `search_screen.dart` carried exactly this: a comment reading "Clears the
/// floating mobile bottom nav" above a hardcoded `SizedBox(height: 120)`. The
/// trailing-spacer shape itself cannot be matched reliably (a leading app-bar
/// spacer in `downloads_screen.dart` is written identically), but a file that
/// *says* it clears the nav should be using the shared widget.
final RegExp _selfDeclaredClearance = RegExp(
  r'clear[s]?.{0,30}(bottom nav|floating.*nav|dock)',
  caseSensitive: false,
);

void main() {
  test('no screen hardcodes its own dock clearance', () {
    final offenders = <String>[];

    final dir = Directory('lib/presentation');
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'flutter test runs with the package root as cwd; '
          'lib/presentation should resolve. cwd is ${Directory.current.path}',
    );

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;

      final source = entity.readAsStringSync();

      for (final match in _hardcodedBottomTernary.allMatches(source)) {
        offenders.add('${entity.path}: ${match.group(0)}');
      }
      for (final match in _selfDeclaredClearance.allMatches(source)) {
        offenders.add('${entity.path}: ${match.group(0)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Use DockInsets.bottomOf(context), or the DockGap / '
          'SliverDockGap widgets, instead of hardcoding dock clearance. The '
          'dock measures 83 with no system inset and 117 with a 34px home '
          'indicator, so any literal is wrong on some device. '
          'Offenders:\n${offenders.join('\n')}',
    );
  });
}
