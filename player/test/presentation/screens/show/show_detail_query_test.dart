import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/show/show_detail_controller.dart';

void main() {
  group('tvShowDetailQuery', () {
    test('selects nextUp with files, so the hero can pick one', () {
      expect(tvShowDetailQuery, contains('nextUp'));
      expect(tvShowDetailQuery, contains('progressState'));

      // The original defect: a second, unused copy of this query requested
      // files while the executed one did not, leaving the play button
      // permanently disabled with nothing to select.
      final nextUpBlock =
          tvShowDetailQuery.substring(tvShowDetailQuery.indexOf('nextUp'));
      expect(nextUpBlock, contains('files'));
      expect(nextUpBlock, contains('directPlaySupported'));
      expect(nextUpBlock, contains('progress'));
      expect(nextUpBlock, contains('positionSeconds'));
    });
  });
}
