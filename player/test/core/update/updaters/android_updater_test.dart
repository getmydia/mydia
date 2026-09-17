import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/android_installer.dart';
import 'package:player/core/update/updaters/android_updater.dart';
import 'package:player/domain/models/available_update.dart';

AppUpdate _update({String? sha256}) => AppUpdate(
      version: '0.16.0-dev.7',
      downloadUrl: 'https://example.invalid/mydia.apk',
      downloadSize: 4,
      sha256: sha256,
      releaseNotesUrl: 'https://example.invalid/commits',
      releaseTitle: '0.16.0-dev.7',
      publishedAt: DateTime.utc(2026, 9, 15),
    );

/// Answers any `download` call with [bytes], mirroring `_StubAdapter` in
/// update_feed_client_test.dart but returning raw bytes instead of JSON, so
/// `Dio.download` has something to stream to disk.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.bytes);

  final List<int> bytes;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(bytes, 200);
  }
}

Dio _dioWriting(List<int> bytes) {
  final dio = Dio();
  dio.httpClientAdapter = _StubAdapter(bytes);
  return dio;
}

void main() {
  late Directory cache;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('mydia-android-updater');
  });

  tearDown(() async {
    if (cache.existsSync()) await cache.delete(recursive: true);
  });

  test('downloads, verifies and installs', () async {
    final installer = _RecordingInstaller();
    final bytes = [1, 2, 3, 4];
    final updater = AndroidUpdater(
      installer: installer,
      dio: _dioWriting(bytes),
      cacheDir: () async => cache,
    );

    final progress = <double>[];
    await updater.applyUpdate(
      _update(sha256: sha256.convert(bytes).toString()),
      onProgress: progress.add,
    );

    expect(installer.installed, isNotNull);
    expect(File(installer.installed!).existsSync(), isTrue);
    expect(progress.last, 1.0);
  });

  test('a digest mismatch installs nothing and deletes the file', () async {
    final installer = _RecordingInstaller();
    final updater = AndroidUpdater(
      installer: installer,
      dio: _dioWriting([1, 2, 3, 4]),
      cacheDir: () async => cache,
    );

    await expectLater(
      updater.applyUpdate(_update(sha256: 'not-the-digest')),
      throwsA(predicate((e) => e.toString().contains('does not match'))),
    );
    expect(installer.installed, isNull);
    expect(cache.listSync(), isEmpty);
  });

  test('an entry with no digest still installs', () async {
    final installer = _RecordingInstaller();
    final updater = AndroidUpdater(
      installer: installer,
      dio: _dioWriting([1, 2, 3, 4]),
      cacheDir: () async => cache,
    );

    await updater.applyUpdate(_update());
    expect(installer.installed, isNotNull);
  });

  test('a refused permission asks for it and stops', () async {
    final installer = _RecordingInstaller(canInstallResult: false);
    final updater = AndroidUpdater(
      installer: installer,
      dio: _dioWriting([1, 2, 3, 4]),
      cacheDir: () async => cache,
    );

    await expectLater(
      updater.applyUpdate(_update()),
      throwsA(isA<InstallerPermissionDenied>()),
    );
    expect(installer.permissionRequested, isTrue);
    expect(installer.installed, isNull);
  });
}

class _RecordingInstaller implements AndroidInstaller {
  _RecordingInstaller({this.canInstallResult = true});

  final bool canInstallResult;
  String? installed;
  bool permissionRequested = false;

  @override
  Future<bool> canInstall() async => canInstallResult;

  @override
  Future<void> requestPermission() async => permissionRequested = true;

  @override
  Future<void> install(String path) async => installed = path;
}
