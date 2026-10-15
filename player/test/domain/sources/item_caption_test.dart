import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

ItemSummary _item(ItemKind kind, {String? subtitle, String? showTitle}) =>
    ItemSummary(
      ref: ItemRef(
        sourceId: const SourceId('a:owner:s'),
        kind: kind,
        externalId: '1',
      ),
      title: 'Lantern Tide',
      subtitle: subtitle,
      showTitle: showTitle,
    );

void main() {
  test('an episode captions with its show and place', () {
    expect(
      showEpisodeCaption(_item(ItemKind.episode,
          showTitle: 'Harbor Lights', subtitle: 'S1 · E3')),
      'Harbor Lights · S1 · E3',
    );
  });

  test('an episode with only a subtitle captions with it', () {
    expect(showEpisodeCaption(_item(ItemKind.episode, subtitle: 'S1 · E3')),
        'S1 · E3');
  });

  test('an episode with neither part has no caption', () {
    expect(showEpisodeCaption(_item(ItemKind.episode)), isNull);
  });

  test('a movie has no caption even with a subtitle', () {
    expect(showEpisodeCaption(_item(ItemKind.movie, subtitle: 'new episodes')),
        isNull);
  });
}
