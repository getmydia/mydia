import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/presentation/screens/detail/source_detail_mapping.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';

void main() {
  test('a source with the mediaInfo capability offers the media info sheet',
      () {
    expect(
        sourceFeatures(FakeCapableSource()), contains(DetailFeature.mediaInfo));
  });

  test('a source without it does not', () {
    expect(sourceFeatures(FakeMediaSource()),
        isNot(contains(DetailFeature.mediaInfo)));
  });
}
