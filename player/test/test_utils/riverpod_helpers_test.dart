import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'riverpod_helpers.dart';

void main() {
  test('resolves once the predicate is satisfied', () async {
    final provider = StreamProvider<int>((ref) => Stream.value(7));
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final value = await waitForValue<int>(
      container,
      provider,
      (value) => value == 7,
    );

    expect(value, 7);
  });

  test(
      'a provider that only ever errors fails with a message naming the '
      'error, not a bare timeout', () async {
    final provider = StreamProvider<int>(
      (ref) => Stream<int>.error(Exception('boom')),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await expectLater(
      waitForValue<int>(
        container,
        provider,
        // A predicate that can never be satisfied: the provider never
        // produces a value, only an error, so this exercises the timeout
        // path specifically.
        (value) => false,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.message,
          'message',
          allOf(contains('timed out'), contains('boom')),
        ),
      ),
    );
  });
}
