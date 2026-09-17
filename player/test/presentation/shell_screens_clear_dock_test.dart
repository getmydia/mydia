// Every screen routed inside the shell sits above the floating mobile dock, so
// every one of them has to reserve its height. Settings and Calendar both
// shipped without doing so: an explicit `ListView.padding` switches off the
// list's own MediaQuery inset, and a `CustomScrollView` never had one.
// `no_magic_dock_padding_test.dart` catches a screen that reserves the wrong
// amount; this catches one that reserves nothing.
//
// Static, because most shell screens need their whole provider graph to mount.
// The cost is that it proves a screen reserves clearance somewhere, not that
// every branch (an empty state, an error state) does.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _routerPath = 'lib/core/router/app_router.dart';

/// Defines `DockGap` itself, so it would satisfy the check for any screen
/// that merely imports it.
const String _dockInsetsPath = 'lib/core/layout/dock_insets.dart';

final RegExp _shellBuilder = RegExp(r'=>\s*(?:const\s+)?([A-Z]\w*Screen)\(');
final RegExp _classDecl = RegExp(r'^class (\w+)', multiLine: true);
final RegExp _import = RegExp(r"""^import '([^']+)'""", multiLine: true);
final RegExp _reservesDock =
    RegExp(r'DockInsets\.bottomOf\(|\bDockGap\(|\bSliverDockGap\(');

/// The source of the `ShellRoute(...)` call, matched by parentheses.
String _shellRouteBlock(String router) {
  final start = router.indexOf('ShellRoute(');
  expect(start, isNot(-1), reason: '$_routerPath has no ShellRoute');

  var depth = 0;
  for (var i = start + 'ShellRoute'.length; i < router.length; i++) {
    final char = router[i];
    if (char == '(') depth++;
    if (char == ')' && --depth == 0) return router.substring(start, i + 1);
  }
  fail('ShellRoute( in $_routerPath has no matching close paren');
}

/// Maps each class declared under `lib/` to the file declaring it.
Map<String, String> _classFiles() {
  final index = <String, String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File) continue;
    final path = entity.path;
    if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
    for (final match in _classDecl.allMatches(entity.readAsStringSync())) {
      index.putIfAbsent(match.group(1)!, () => path);
    }
  }
  return index;
}

/// [path] plus the files it imports directly from this package.
List<String> _withDirectImports(String path) {
  final dir = File(path).parent.uri;
  final files = [path];
  for (final match in _import.allMatches(File(path).readAsStringSync())) {
    final target = match.group(1)!;
    if (target.startsWith('dart:')) continue;
    final resolved = target.startsWith('package:player/')
        ? 'lib/${target.substring('package:player/'.length)}'
        : target.startsWith('package:')
            ? null
            : dir.resolve(target).toFilePath();
    if (resolved == null || resolved == _dockInsetsPath) continue;
    files.add(resolved);
  }
  return files;
}

String _withoutLineComments(String source) =>
    source.split('\n').map((line) => line.split('//').first).join('\n');

bool _reservesClearance(String path) => _withDirectImports(path).any(
      (file) =>
          File(file).existsSync() &&
          _reservesDock
              .hasMatch(_withoutLineComments(File(file).readAsStringSync())),
    );

void main() {
  test('every shell screen reserves dock clearance', () {
    final router = File(_routerPath);
    expect(
      router.existsSync(),
      isTrue,
      reason: 'flutter test runs with the package root as cwd; '
          '$_routerPath should resolve. cwd is ${Directory.current.path}',
    );

    final screens = _shellBuilder
        .allMatches(_shellRouteBlock(router.readAsStringSync()))
        .map((m) => m.group(1)!)
        .toSet();

    expect(
      screens,
      allOf(contains('HomeScreen'), contains('SettingsScreen')),
      reason: 'The ShellRoute in $_routerPath no longer matches the shape '
          'this test parses. Update _shellBuilder rather than deleting the '
          'test. Found: $screens',
    );
    expect(screens.length, greaterThanOrEqualTo(10), reason: '$screens');

    final classFiles = _classFiles();
    final offenders = <String>[];
    for (final screen in screens) {
      final path = classFiles[screen];
      if (path == null) {
        offenders.add('$screen (no declaring file found under lib/)');
      } else if (!_reservesClearance(path)) {
        offenders.add('$screen ($path)');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These screens are routed inside the ShellRoute, where the '
          'floating dock covers the bottom of the viewport, but neither the '
          'screen nor anything it imports directly reserves its height. Use '
          'DockInsets.bottomOf(context) for a ListView or GridView padding, '
          'DockGap at the end of a Column, or SliverDockGap as the last '
          'sliver. An explicit `padding:` on a ListView or GridView turns off '
          'its automatic MediaQuery inset, so it needs one of these too.\n'
          '${offenders.join('\n')}',
    );
  });
}
