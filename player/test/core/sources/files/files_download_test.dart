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
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

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
  const filePath = '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.mkv';
  final versionKey =
      fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv');

  runMediaSourceContract('Network Files (WebDAV)', () async {
    final (f, source) = await _buildSource(
      _webdavSource,
      _WebDavFakeBackend({filePath: 1000}),
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
      _WebDavFakeBackend({filePath: 1000}),
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
  });
}
