import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/detail/detail_screen_frame.dart';
import 'package:player/presentation/screens/detail/detail_states.dart';

import '../../../helpers/cast_test_overrides.dart';
import '../sources/fake_media_source.dart' show fakeSourceId;
import 'detail_harness.dart';

const _target = SourceTarget(
  ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm1'),
);

Future<void> _pumpSliverScreen(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: castCapableOverrides(),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('DetailLoadingState', () {
    testWidgets('shows a spinner under the hero and the back button',
        (tester) async {
      await _pumpSliverScreen(tester, const DetailLoadingState());
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    });
  });

  group('DetailErrorState', () {
    testWidgets('names the noun, shows the error, and retries on tap',
        (tester) async {
      var retries = 0;
      await _pumpSliverScreen(
        tester,
        DetailErrorState(
          noun: 'TV show',
          error: 'boom',
          onRetry: () => retries++,
        ),
      );
      await tester.pump();

      expect(find.text('Failed to load TV show'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);

      await tester.tap(find.text('Try Again'));
      expect(retries, 1);
    });
  });

  group('DetailScreenFrame', () {
    testWidgets('renders the builder for data', (tester) async {
      await pumpDetailScreen(
        tester,
        DetailScreenFrame<String>(
          target: _target,
          value: const AsyncValue.data('loaded'),
          noun: 'movie',
          onRetry: () {},
          builder: (context, data) => Text('content: $data'),
        ),
        const [],
      );

      expect(find.text('content: loaded'), findsOneWidget);
    });

    testWidgets('renders the error state for an error', (tester) async {
      var retries = 0;
      await pumpDetailScreen(
        tester,
        DetailScreenFrame<String>(
          target: _target,
          value: const AsyncValue.error('boom', StackTrace.empty),
          noun: 'movie',
          onRetry: () => retries++,
          builder: (context, data) => Text('content: $data'),
        ),
        const [],
      );

      expect(find.text('Failed to load movie'), findsOneWidget);
      await tester.tap(find.text('Try Again'));
      expect(retries, 1);
    });
  });
}
