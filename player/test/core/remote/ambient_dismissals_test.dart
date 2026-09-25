import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/ambient_dismissals.dart';

void main() {
  test('dismissKey records the key', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(ambientDismissalsProvider.notifier)
        .dismissKey(const AmbientDismissal('node-tv', 'The Lantern Keepers'));

    expect(container.read(ambientDismissalsProvider),
        {const AmbientDismissal('node-tv', 'The Lantern Keepers')});
  });

  test('dismissKey keeps earlier dismissals', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(ambientDismissalsProvider.notifier);

    notifier
        .dismissKey(const AmbientDismissal('node-tv', 'The Lantern Keepers'));
    notifier.dismissKey(const AmbientDismissal('node-den', 'Harbour of Glass'));

    expect(container.read(ambientDismissalsProvider), hasLength(2));
  });
}
