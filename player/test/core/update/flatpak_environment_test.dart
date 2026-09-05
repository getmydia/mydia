import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/flatpak_environment.dart';

/// A trimmed copy of the real /.flatpak-info from an installed
/// dev.mydia.player, keeping only the keys the parser reads plus enough
/// noise to prove section handling works. Also carries the two hardest lines
/// a real file contains: a value with more than one "=" in it, and a section
/// header with a space in its name.
const _stableInfo = '''
[Application]
name=dev.mydia.player
runtime=runtime/org.gnome.Platform/x86_64/50

[Instance]
instance-id=114688807
app-commit=14c05ae630f829be49770831541c3777fad915ba3ce304c4d46eff016b442ec6
runtime-extensions=org.gnome.Platform.Locale=b985d62;org.freedesktop.Platform.GL.default=bcfd828
branch=stable
arch=x86_64
flatpak-version=1.18.1

[Context]
shared=ipc;network;

[Session Bus Policy]
org.freedesktop.ScreenSaver=talk
''';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('mydia-flatpak-info'));
  tearDown(() => temp.deleteSync(recursive: true));

  String write(String contents) {
    final file = File('${temp.path}/flatpak-info');
    file.writeAsStringSync(contents);
    return file.path;
  }

  test('a missing file means this is not a Flatpak', () {
    final env = FlatpakEnvironment(infoPath: '${temp.path}/absent');

    expect(env.isFlatpak, isFalse);
    expect(env.appId, isNull);
    expect(env.branch, isNull);
  });

  test('reads the app id and branch from a stable install', () {
    final env = FlatpakEnvironment(infoPath: write(_stableInfo));

    expect(env.isFlatpak, isTrue);
    expect(env.appId, 'dev.mydia.player');
    expect(env.branch, 'stable');
  });

  test('reads the beta branch', () {
    final env = FlatpakEnvironment(
      infoPath: write(_stableInfo.replaceFirst('branch=stable', 'branch=beta')),
    );

    expect(env.branch, 'beta');
  });

  test('a present but unparseable file is still a Flatpak', () {
    // The sandbox is real even if the format changed under us. Reporting
    // isFlatpak false here would route the app back to LinuxUpdater, which is
    // the exact failure this work exists to remove.
    final env = FlatpakEnvironment(infoPath: write('nonsense'));

    expect(env.isFlatpak, isTrue);
    expect(env.appId, isNull);
    expect(env.branch, isNull);
  });

  test('name outside the Application section is not the app id', () {
    final env = FlatpakEnvironment(
      infoPath: write('[Context]\nname=not-the-app\n'),
    );

    expect(env.appId, isNull);
  });

  test('reads the right values out of a realistic full-shape file', () {
    // _stableInfo carries a value with an embedded "=" and a section header
    // with a space in it, both present in a real /.flatpak-info. This proves
    // the lookup still finds the right values in that fuller shape, not only
    // in the trimmed fixture the other tests use.
    final env = FlatpakEnvironment(infoPath: write(_stableInfo));

    expect(env.appId, 'dev.mydia.player');
    expect(env.branch, 'stable');
  });
}
