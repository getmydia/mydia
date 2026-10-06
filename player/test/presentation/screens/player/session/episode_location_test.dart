import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/core/p2p/local_proxy_service.dart';

import '../../../../test_utils/mydia_test_source.dart';
import '../../../../test_utils/scripted_mydia_transport.dart';

void main() {
  test('Mydia uses the source-scoped player route', () {
    final source = testMydiaSourceOver(
        ScriptedMydiaTransport.responses([<String, dynamic>{}]));
    final session = MydiaPlaybackSession(
      source: source,
      item: ItemRef(
          sourceId: source.id, kind: ItemKind.episode, externalId: 'e1'),
      fileId: 'f1',
      showId: 's1',
      seasonNumber: 1,
      proxy: LocalProxyService.forTesting,
    );
    expect(
      session.episodeLocation(
        episodeId: 'e2',
        fileId: 'f2',
        title: 'Invented Series - S01E02',
        seasonNumber: 1,
        showId: 's1',
      ),
      '/s/${source.id.value}/player/e2?kind=episode'
      '&fileId=f2'
      '&title=${Uri.encodeQueryComponent('Invented Series - S01E02')}'
      '&seasonNumber=1&showId=s1',
    );
  });
}
