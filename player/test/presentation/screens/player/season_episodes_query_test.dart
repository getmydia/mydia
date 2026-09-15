import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart' show printNode;
import 'package:player/graphql/queries/season_episodes.graphql.dart';

void main() {
  group('SeasonEpisodes query', () {
    test('selects file ids without subtitles, so large seasons fit over p2p',
        () {
      final queryText = printNode(documentNodeQuerySeasonEpisodes);

      // Next episode, previous episode and Up Next need each file's id.
      final filesBlock = queryText.substring(queryText.indexOf('files'));
      expect(filesBlock, contains('id'));

      // The defect: the whole MediaFileFragment, subtitles included, pushed a
      // season with many subtitle tracks to 254 KB, past what a p2p response
      // could carry, so the query failed on those seasons every time.
      expect(queryText, isNot(contains('subtitles')));
      expect(queryText, isNot(contains('MediaFileFragment')));
    });
  });
}
