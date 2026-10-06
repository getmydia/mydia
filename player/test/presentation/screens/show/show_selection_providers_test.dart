import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/show/show_selection_providers.dart';

const _show = ItemRef(
    sourceId: SourceId('a:b:c'), kind: ItemKind.show, externalId: 'sh-1');
const _otherShow = ItemRef(
    sourceId: SourceId('a:b:c'), kind: ItemKind.show, externalId: 'sh-2');
const _sameIdOtherSource = ItemRef(
    sourceId: SourceId('d:e:f'), kind: ItemKind.show, externalId: 'sh-1');

void main() {
  group('selectedEpisodeProvider', () {
    test('defaults to null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(selectedEpisodeProvider(_show)), isNull);
    });

    test('select() sets the state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(selectedEpisodeProvider(_show).notifier).select('ep-5');

      expect(container.read(selectedEpisodeProvider(_show)), 'ep-5');
    });

    test('is scoped independently per show and per source', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(selectedEpisodeProvider(_show).notifier).select('ep-5');

      expect(container.read(selectedEpisodeProvider(_otherShow)), isNull);
      expect(
          container.read(selectedEpisodeProvider(_sameIdOtherSource)), isNull);
    });
  });

  group('selectedSeasonProvider', () {
    test('starts on season 1 and is scoped per source', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(selectedSeasonProvider(_show)), 1);
      container.read(selectedSeasonProvider(_show).notifier).select(3);

      expect(container.read(selectedSeasonProvider(_show)), 3);
      expect(container.read(selectedSeasonProvider(_sameIdOtherSource)), 1);
    });
  });
}
