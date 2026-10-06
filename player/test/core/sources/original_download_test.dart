import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/original_download.dart';
import 'package:player/domain/sources/item.dart';

import '../../presentation/screens/sources/fake_media_source.dart';

void main() {
  test('estimates size from bitrate and duration', () {
    expect(
        estimatedBytes(const MediaVersion(
            id: 'v', bitrateKbps: 8000, durationSeconds: 10)),
        10000000);
    expect(estimatedBytes(const MediaVersion(id: 'v')), isNull);
  });

  test('the original option names its container', () {
    final option = originalOption(const MediaVersion(
        id: 'v', container: 'mkv', bitrateKbps: 8, durationSeconds: 1));
    expect(option.resolution, originalOptionId);
    expect(option.label, 'Original');
    expect(option.container, 'mkv');
  });

  test('originalFile resolves the default version with its headers', () async {
    final source = FakeMediaSource();
    final file = await originalFile(
      source,
      fakeMovie(1).ref,
      url: (v) async => Uri.parse('https://srv.invalid/file/${v.id}'),
      headers: () async => {'ApiKey': 'k'},
    );
    expect(file.url, 'https://srv.invalid/file/part-1');
    expect(file.headers, {'ApiKey': 'k'});
    expect(file.extension, 'mkv');
  });
}
