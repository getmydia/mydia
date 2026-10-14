import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_providers.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';

const _night =
    BackdropSource(imageUrl: 'https://art/night-ferry.jpg', id: 'nf');
const _salt = BackdropSource(imageUrl: 'https://art/saltmarsh.jpg', id: 'sm');

ProviderContainer _container(List<BackdropSource> calls, {Color? seed}) {
  final container = ProviderContainer(overrides: [
    tintExtractorProvider.overrideWithValue((source) async {
      calls.add(source);
      return seed;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('no artwork resolves neutral without extracting', () async {
    final calls = <BackdropSource>[];
    final c = _container(calls, seed: const Color(0xFF2F4A9F));
    expect(await c.read(tintForSourceProvider(BackdropSource.none).future),
        AmbientTintColors.neutral);
    expect(calls, isEmpty);
  });

  test('a null seed resolves neutral', () async {
    final c = _container([]);
    expect(await c.read(tintForSourceProvider(_night).future),
        AmbientTintColors.neutral);
  });

  test('a second request for the same id is a cache hit', () async {
    final calls = <BackdropSource>[];
    final c = _container(calls, seed: const Color(0xFF2F4A9F));
    final sub = c.listen(tintForSourceProvider(_night).future, (_, __) {});
    await sub.read();
    sub.close();
    await Future<void>.delayed(Duration.zero); // let autoDispose run
    await c.read(tintForSourceProvider(_night).future);
    expect(calls, hasLength(1));
  });

  test('an extractor error resolves neutral', () async {
    final container = ProviderContainer(overrides: [
      tintExtractorProvider
          .overrideWithValue((_) async => throw Exception('x')),
    ]);
    addTearDown(container.dispose);
    expect(await container.read(tintForSourceProvider(_night).future),
        AmbientTintColors.neutral);
  });

  test('the controller debounces source changes', () {
    fakeAsync((async) {
      final calls = <BackdropSource>[];
      final c = _container(calls, seed: const Color(0xFF2F4A9F));
      c.listen(ambientTintControllerProvider, (_, __) {});
      final backdrop = c.read(ambientBackdropControllerProvider.notifier);
      backdrop.setHover(_night);
      async.elapse(const Duration(milliseconds: 50));
      backdrop.setHover(_salt);
      async.elapse(const Duration(milliseconds: 50));
      expect(calls, isEmpty);
      async.elapse(AmbientTintController.debounce);
      async.flushMicrotasks();
      expect(calls, [_salt]);
      expect(c.read(ambientTintControllerProvider),
          isNot(AmbientTintColors.neutral));
    });
  });
}
