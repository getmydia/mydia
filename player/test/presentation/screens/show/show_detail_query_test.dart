import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart' show printNode;
import 'package:player/graphql/queries/show_detail.graphql.dart';

void main() {
  group('TvShowDetail query', () {
    test('selects nextUp with files, so the hero can pick one', () {
      final queryText = printNode(documentNodeQueryTvShowDetail);

      expect(queryText, contains('nextUp'));
      expect(queryText, contains('progressState'));

      // The original defect: a second, unused copy of this query requested
      // files while the executed one did not, leaving the play button
      // permanently disabled with nothing to select.
      final nextUpBlock = queryText.substring(queryText.indexOf('nextUp'));
      expect(nextUpBlock, contains('files'));
      expect(nextUpBlock, contains('directPlaySupported'));
      expect(nextUpBlock, contains('progress'));
      expect(nextUpBlock, contains('positionSeconds'));
    });
  });
}
