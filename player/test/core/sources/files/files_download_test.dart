import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/original_download.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

import '../media_source_contract.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

String webdavAccountId(Uri url) => webDavAccountId(url);

class _WebDavFakeBackend extends FakeBackend {
  _WebDavFakeBackend(super.files);

  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(
        url: 'https://dav.example$path',
        headers: const {'Authorization': 'Basic dXNlcjpwYXNz'},
      );
}

class _FaultyBackend extends FakeBackend {
  _FaultyBackend(super.files);

  BackendFailure? failure;

  @override
  Future<FileEntry?> stat(String path) async {
    final f = failure;
    if (f != null) throw f;
    return super.stat(path);
  }
}

final _webdavAccountId =
    webdavAccountId(Uri.parse('https://dav.example/media'));

final _webdavSource = Source(
  account: ProviderAccount(
    id: _webdavAccountId,
    kind: SourceKind.files,
    displayName: 'dav.example',
    storageNamespace: 'source/$_webdavAccountId',
    activeProfileId: kOwnerProfileId,
  ),
  profile: SourceProfile(
    id: kOwnerProfileId,
    accountId: _webdavAccountId,
    name: 'Owner',
    isOwner: true,
  ),
  server: SourceServer(
    id: _webdavAccountId,
    accountId: _webdavAccountId,
    profileId: kOwnerProfileId,
    name: 'dav.example',
  ),
);

Future<(FilesFixture, FilesMediaSource)> _buildSource(
  Source source,
  FileSystemBackend backend,
) async {
  final f = await FilesFixture.create();
  final relay = FakeFilesRelay();
  final mediaSource = FilesMediaSource(
    source: source,
    backend: backend,
    index: f.index,
    progress: f.progress,
    matcher: FileMatcher(
      tmdb: relay,
      names: FakeMediaNames(),
      index: f.index,
      progress: f.progress,
      sourceId: source.id,
    ),
    tmdb: relay,
    invalidate: (_) async {},
    l10n: () => filesL10n,
  );
  addTearDown(mediaSource.dispose);
  return (f, mediaSource);
}

void main() {
  const filePath1080 =
      '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.mkv';
  const filePath = '${FilesFixture.rootPath}/B/Copper Valley (2018) 2160p.mkv';
  final versionKey =
      fileKeyFor(FilesFixture.rootId, 'B/Copper Valley (2018) 2160p.mkv');
  final versionKey1080 =
      fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv');

  runMediaSourceContract('Network Files (WebDAV)', () async {
    final (f, source) = await _buildSource(
      _webdavSource,
      _WebDavFakeBackend({filePath: 1000, filePath1080: 1000}),
    );
    return ContractFixture(
      source: source,
      library: LibraryRef(sourceId: _webdavSource.id, id: FilesFixture.rootId),
      playable: ItemRef(
        sourceId: _webdavSource.id,
        kind: ItemKind.movie,
        externalId: '101',
      ),
      libraryItemCount: 3,
      show: ItemRef(
        sourceId: _webdavSource.id,
        kind: ItemKind.show,
        externalId: '201',
      ),
    );
  });

  test('local files source is castable but not downloadable', () async {
    final (_, source) = await _buildSource(
      filesLocalSource,
      FakeBackend({filePath: 1000}),
    );
    expect(source.capabilities, contains(SourceCapability.castable));
    expect(source.capabilities, isNot(contains(SourceCapability.downloadable)));
    expect(source.as<Downloadable>(), isNull);
  });

  test('network files source offers Original download with exact file size',
      () async {
    final (_, source) = await _buildSource(
      _webdavSource,
      _WebDavFakeBackend({filePath: 1000, filePath1080: 1000}),
    );
    expect(source.capabilities, contains(SourceCapability.downloadable));
    expect(source.capabilities, contains(SourceCapability.castable));

    final downloadable = source.as<Downloadable>();
    expect(downloadable, isNotNull);

    final movieRef = ItemRef(
      sourceId: _webdavSource.id,
      kind: ItemKind.movie,
      externalId: '101',
    );
    final options = await downloadable!.downloadOptions(movieRef);
    expect(options, hasLength(1));
    final option = options.single;
    expect(option.id, kOriginalDownloadOptionId);
    expect(option.type, DownloadType.original);
    expect(option.actualSize, 1000);
    expect(option.estimatedSize, 1000);

    final prepared =
        await downloadable.prepareDownload(movieRef, versionKey, option);
    expect(prepared.url, 'https://dav.example$filePath');
    expect(prepared.headers, {'Authorization': 'Basic dXNlcjpwYXNz'});
    expect(prepared.container, 'mkv');
    expect(prepared.expectedBytes, 1000);

    final resolved =
        await downloadable.resolve(movieRef, option.id) as DirectFile;
    expect(resolved.url, prepared.url);
    expect(resolved.headers, prepared.headers);
    expect(resolved.extension, prepared.container);
    expect(resolved.expectedBytes, prepared.expectedBytes);

    final prepared1080 =
        await downloadable.prepareDownload(movieRef, versionKey1080, option);
    expect(prepared1080.url, 'https://dav.example$filePath1080');
    expect(prepared1080.container, 'mkv');
  });

  test('downloadable maps BackendFailure to SourceException', () async {
    final backend = _FaultyBackend({filePath: 1000, filePath1080: 1000});
    final (_, source) = await _buildSource(_webdavSource, backend);
    final downloadable = source.as<Downloadable>()!;

    final movieRef = ItemRef(
      sourceId: _webdavSource.id,
      kind: ItemKind.movie,
      externalId: '101',
    );
    final options = await downloadable.downloadOptions(movieRef);
    final option = options.single;

    // BackendUnauthorized -> SourceException.unauthorized
    backend.failure = const BackendUnauthorized('bad credentials');
    await expectLater(
      downloadable.resolve(movieRef, option.id),
      throwsA(isA<SourceException>().having(
        (e) => e.kind,
        'kind',
        SourceErrorKind.unauthorized,
      )),
    );
    await expectLater(
      downloadable.prepareDownload(movieRef, versionKey, option),
      throwsA(isA<SourceException>().having(
        (e) => e.kind,
        'kind',
        SourceErrorKind.unauthorized,
      )),
    );

    // BackendPermissionLost -> SourceException.unauthorized
    backend.failure = const BackendPermissionLost('storage access lost');
    await expectLater(
      downloadable.resolve(movieRef, option.id),
      throwsA(isA<SourceException>().having(
        (e) => e.kind,
        'kind',
        SourceErrorKind.unauthorized,
      )),
    );
    await expectLater(
      downloadable.prepareDownload(movieRef, versionKey, option),
      throwsA(isA<SourceException>().having(
        (e) => e.kind,
        'kind',
        SourceErrorKind.unauthorized,
      )),
    );

    // BackendNotFound -> SourceException.notFound
    backend.failure = const BackendNotFound('file missing');
    await expectLater(
      downloadable.resolve(movieRef, option.id),
      throwsA(isA<SourceException>().having(
        (e) => e.kind,
        'kind',
        SourceErrorKind.notFound,
      )),
    );
    await expectLater(
      downloadable.prepareDownload(movieRef, versionKey, option),
      throwsA(isA<SourceException>().having(
        (e) => e.kind,
        'kind',
        SourceErrorKind.notFound,
      )),
    );
  });
}
