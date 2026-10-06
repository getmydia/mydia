import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  group('extensionForContainer', () {
    test('keeps a plain container name', () {
      expect(extensionForContainer('mkv'), 'mkv');
      expect(extensionForContainer('MP4'), 'mp4');
    });
    test('maps long names to their extension', () {
      expect(extensionForContainer('matroska'), 'mkv');
      expect(extensionForContainer('mpegts'), 'ts');
      expect(extensionForContainer('quicktime'), 'mov');
    });
    test('takes the first of a comma list', () {
      expect(extensionForContainer('mov,mp4,m4a'), 'mov');
    });
    test('falls back to mp4 when unknown or unsafe', () {
      expect(extensionForContainer(null), 'mp4');
      expect(extensionForContainer(''), 'mp4');
      expect(extensionForContainer('../etc'), 'mp4');
    });
  });

  test('homeMydiaRef points at the legacy source', () {
    final ref = homeMydiaRef(ItemKind.episode, 'e7');
    expect(ref.sourceId, SourceId.legacyMydia);
    expect(ref.kind, ItemKind.episode);
    expect(ref.externalId, 'e7');
  });
}
