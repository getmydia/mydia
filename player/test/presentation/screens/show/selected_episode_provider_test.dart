import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/show/show_detail_controller.dart';

void main() {
  group('selectedEpisodeProvider', () {
    test('defaults to null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(selectedEpisodeProvider('sh-1')), isNull);
    });

    test('select() sets the state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(selectedEpisodeProvider('sh-1').notifier).select('ep-5');

      expect(container.read(selectedEpisodeProvider('sh-1')), 'ep-5');
    });

    test('is scoped independently per show id', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(selectedEpisodeProvider('sh-1').notifier).select('ep-5');

      expect(container.read(selectedEpisodeProvider('sh-2')), isNull);
    });
  });
}
