import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/current_source_status.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/banner_button.dart';
import 'package:player/presentation/widgets/offline_banner.dart';

import '../screens/sources/fake_media_source.dart';

class _Selected extends SelectedSourceNotifier {
  @override
  SourceId? build() => _idA;

  @override
  void select(SourceId id) => state = id;
}

const _idA = SourceId('acc1:owner:aa11');
const _idB = SourceId('acc2:owner:bb22');

/// The shell's rule: the banner shows while the current source is
/// unreachable.
class _Host extends ConsumerWidget {
  const _Host({this.location = '/'});

  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: isOffline(ref.watch(routeSourceStatusProvider(location)))
            ? OfflineBanner(location: location)
            : const SizedBox.shrink(),
      );
}

void main() {
  late FakeMediaSource a;
  late FakeMediaSource b;
  late int builtA;
  late int builtB;
  late ProviderContainer container;

  setUp(() {
    a = FakeMediaSource();
    b = FakeMediaSource();
    builtA = 0;
    builtB = 0;
  });

  Future<void> pump(WidgetTester tester, {String location = '/'}) async {
    container = ProviderContainer(overrides: [
      selectedSourceIdProvider.overrideWith(_Selected.new),
      activeSourceIdProvider
          .overrideWith((ref) => ref.watch(selectedSourceIdProvider)),
      mediaSourceProvider(_idA).overrideWith((ref) {
        builtA++;
        return a;
      }),
      mediaSourceProvider(_idB).overrideWith((ref) {
        builtB++;
        return b;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: _Host(location: location)),
    ));
  }

  testWidgets('shows with Retry while unreachable, hides when remote',
      (tester) async {
    a.setStatus(SourceConnectionStatus.unreachable);
    await pump(tester);

    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.widgetWithText(BannerButton, 'Retry'), findsOneWidget);

    a.setStatus(SourceConnectionStatus.remote);
    await tester.pump();
    expect(find.byType(OfflineBanner), findsNothing);
  });

  testWidgets('only the current source decides: A offline, B fine',
      (tester) async {
    a.setStatus(SourceConnectionStatus.unreachable);
    await pump(tester);
    expect(find.byType(OfflineBanner), findsOneWidget);

    container.read(selectedSourceIdProvider.notifier).select(_idB);
    await tester.pump();
    expect(find.byType(OfflineBanner), findsNothing);

    container.read(selectedSourceIdProvider.notifier).select(_idA);
    await tester.pump();
    expect(find.byType(OfflineBanner), findsOneWidget);
  });

  testWidgets('Retry rebuilds the selected source', (tester) async {
    a.setStatus(SourceConnectionStatus.unreachable);
    await pump(tester);
    expect(builtA, 1);

    await tester.tap(find.widgetWithText(BannerButton, 'Retry'));
    await tester.pump();

    expect(builtA, 2);
  });

  testWidgets('Retry rebuilds the source on screen, not the active one',
      (tester) async {
    b.setStatus(SourceConnectionStatus.unreachable);
    await pump(tester, location: '/s/${_idB.value}');
    expect(find.byType(OfflineBanner), findsOneWidget);
    // A is the active source; the first read of A builds it once.
    container.read(mediaSourceProvider(_idA));
    expect((builtA, builtB), (1, 1));

    await tester.tap(find.widgetWithText(BannerButton, 'Retry'));
    await tester.pump();

    expect(builtB, 2);
    expect(builtA, 1);
  });
}
