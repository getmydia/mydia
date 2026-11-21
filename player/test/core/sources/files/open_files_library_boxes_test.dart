import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/peer_files_host.dart'
    show HivePeerFilesRevisions;
import 'package:player/core/p2p/peer_files_store.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('open_files_boxes_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a copies box that will not open leaves the rest open', () async {
    // A directory where the box file goes: opening it fails, as a corrupt
    // box does.
    await Directory('${dir.path}/${PeerFilesStore.boxName}.hive').create();

    await openFilesLibraryBoxes();

    expect(Hive.isBoxOpen(FileLibraryIndex.boxName), isTrue);
    expect(Hive.isBoxOpen(HivePlaybackProgressStore.boxName), isTrue);
    expect(Hive.isBoxOpen(PeerSyncStore.boxName), isTrue);
    expect(Hive.isBoxOpen(HivePeerFilesRevisions.boxName), isTrue);
    expect(Hive.isBoxOpen(PeerFilesStore.boxName), isFalse);
  });
}
