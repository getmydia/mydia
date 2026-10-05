import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

import '../../presentation/screens/sources/fake_media_source.dart';

void main() {
  test('home is always visible; sources only while listed', () {
    final hidden = ProviderContainer(
        overrides: [thirdPartySourcesProvider.overrideWithValue(const [])]);
    addTearDown(hidden.dispose);
    expect(hidden.read(visibleDownloadSourcesProvider), {SourceId.legacyMydia});

    final shown = ProviderContainer(overrides: [
      thirdPartySourcesProvider.overrideWithValue([fakeSource])
    ]);
    addTearDown(shown.dispose);
    expect(shown.read(visibleDownloadSourcesProvider),
        {SourceId.legacyMydia, fakeSourceId});
  });
}
