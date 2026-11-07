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

  test('forgetNode drops every dismissal for that player only', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(ambientDismissalsProvider.notifier);

    notifier
        .dismissKey(const AmbientDismissal('node-tv', 'The Lantern Keepers'));
    notifier.dismissKey(const AmbientDismissal('node-tv', 'Harbour of Glass'));
    notifier.dismissKey(const AmbientDismissal('node-den', 'Harbour of Glass'));

    notifier.forgetNode('NODE-TV');

    expect(container.read(ambientDismissalsProvider),
        {const AmbientDismissal('node-den', 'Harbour of Glass')});
  });

  test('forgetNode leaves state untouched when nothing matches', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(ambientDismissalsProvider.notifier);
    notifier.dismissKey(const AmbientDismissal('node-den', 'Harbour of Glass'));
    final before = container.read(ambientDismissalsProvider);

    notifier.forgetNode('node-tv');

    expect(identical(container.read(ambientDismissalsProvider), before), isTrue,
        reason: 'an idle report for an undismissed player must not '
            'rebuild every listener');
  });

  test('clear drops every dismissal', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(ambientDismissalsProvider.notifier);
    notifier
        .dismissKey(const AmbientDismissal('node-tv', 'The Lantern Keepers'));
    notifier.dismissKey(const AmbientDismissal('node-den', 'Harbour of Glass'));

    notifier.clear();

    expect(container.read(ambientDismissalsProvider), isEmpty);
  });
}
