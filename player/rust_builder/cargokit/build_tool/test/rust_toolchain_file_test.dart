// LOCAL CHANGE (mydia, #252): not part of upstream Cargokit.
//
// Run with `dart run test/rust_toolchain_file_test.dart`, not `dart test`.
// The `dart test` runner fails to load anything in this package, including a
// trivial smoke test, because build_tool deliberately pins old versions of
// path/source_span/yaml (see the comment in pubspec.yaml) that the current
// runner cannot operate with. `dart run` executes the same package:test
// assertions and reports the same pass/fail.

import 'dart:io';

import 'package:build_tool/src/rust_toolchain_file.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rust_toolchain_file_test');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  void writeToolchain(String contents) {
    File(path.join(root.path, 'rust-toolchain.toml'))
        .writeAsStringSync(contents);
  }

  Directory nested() {
    final dir = Directory(path.join(root.path, 'player', 'rust', 'crate'));
    dir.createSync(recursive: true);
    return dir;
  }

  test('reads the channel from the start directory', () {
    writeToolchain('[toolchain]\nchannel = "1.96.0"\n');
    expect(resolveToolchainChannel(root.path), '1.96.0');
  });

  test('walks up to an ancestor directory', () {
    writeToolchain('[toolchain]\nchannel = "1.96.0"\n');
    expect(resolveToolchainChannel(nested().path), '1.96.0');
  });

  test('returns null when no file exists anywhere above', () {
    expect(resolveToolchainChannel(nested().path), isNull);
  });

  test('returns null when the file declares no channel', () {
    writeToolchain('[toolchain]\nprofile = "minimal"\n');
    expect(resolveToolchainChannel(root.path), isNull);
  });

  test('returns null when the file is not valid TOML', () {
    writeToolchain('this is not toml [[[');
    expect(resolveToolchainChannel(root.path), isNull);
  });

  test('passes a floating channel through unchanged', () {
    writeToolchain('[toolchain]\nchannel = "nightly"\n');
    expect(resolveToolchainChannel(root.path), 'nightly');
  });
}
