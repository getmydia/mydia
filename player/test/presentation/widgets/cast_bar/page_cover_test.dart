import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/router/page_cover_observer.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/cast_bar/dock_extents.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';

// AppShell itself needs the authenticated provider graph and cannot be
// mounted here. `_ShellLike` makes the same calls the shell's mobile branch
// makes (`ModalRoute.of`, `PageCoverObserver.isCovered`,
// `AppShell.nativeBarReported` / `nativeBarVisible`), so this covers the
// decision logic and CastBarLayer's reaction to it.

const _name = 'test/native-tab-bar';
const _device = CastDevice(
  id: 'd1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

class _Popup extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
          BuildContext context, Animation<double> a, Animation<double> b) =>
      const SizedBox();
}

class _ShellLike extends StatefulWidget {
  const _ShellLike({required this.observer, required this.visibleLog});

  final PageCoverObserver observer;
  final List<bool> visibleLog;

  @override
  State<_ShellLike> createState() => _ShellLikeState();
}

class _ShellLikeState extends State<_ShellLike> {
  @override
  void initState() {
    super.initState();
    widget.observer.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.observer.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final shellCurrent = route?.isCurrent ?? true;
    final covered = widget.observer.isCovered(route);
    widget.visibleLog.add(AppShell.nativeBarVisible(
        shellCurrent: shellCurrent, drawerOpen: false));
    return ReportedNativeBar(
      shown: AppShell.nativeBarReported(native: true, coveredByPage: covered),
      child: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  key: const Key('dialog'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(title: Text('Hi')),
                  ),
                  child: const Text('dialog'),
                ),
                ElevatedButton(
                  key: const Key('sheet'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(height: 100),
                  ),
                  child: const Text('sheet'),
                ),
                ElevatedButton(
                  key: const Key('page'),
                  onPressed: () => context.push('/page'),
                  child: const Text('page'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<List<bool>> _pump(WidgetTester tester) async {
  final visibleLog = <bool>[];
  final observer = PageCoverObserver();
  addTearDown(observer.dispose);
  const channel = MethodChannel(_name);
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (_) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  final container = ProviderContainer(overrides: [
    castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    hasMydiaProvider.overrideWithValue(true),
    castSessionProvider.overrideWith((ref) => Stream.value(null)),
    nativeTabBarChannelProvider.overrideWith((ref) {
      final c = NativeTabBarChannel(channel: channel);
      ref.onDispose(c.dispose);
      return c;
    }),
  ]);
  addTearDown(container.dispose);

  final router = GoRouter(observers: [
    observer
  ], routes: [
    GoRoute(
      path: '/',
      builder: (_, __) =>
          _ShellLike(observer: observer, visibleLog: visibleLog),
    ),
    GoRoute(
      path: '/page',
      builder: (_, __) => const Scaffold(body: Text('a page')),
    ),
  ]);
  addTearDown(router.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      builder: (context, child) =>
          CastBarLayer(child: child ?? const SizedBox.shrink()),
    ),
  ));
  container.read(castTargetProvider.notifier).set(_device);
  await tester.pump();
  return visibleLog;
}

void main() {
  group('PageCoverObserver.coveredByPage', () {
    final shell = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final page = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final popup = _Popup();

    test('a page above the shell covers it', () {
      expect(PageCoverObserver.coveredByPage(shell, [shell, page]), isTrue);
    });

    test('a popup above the shell does not', () {
      expect(PageCoverObserver.coveredByPage(shell, [shell, popup]), isFalse);
    });

    test('a page below the shell, or no shell, does not', () {
      expect(PageCoverObserver.coveredByPage(shell, [page, shell]), isFalse);
      expect(PageCoverObserver.coveredByPage(null, [shell, page]), isFalse);
      expect(PageCoverObserver.coveredByPage(shell, [page]), isFalse);
    });

    test('a page under a popup still covers', () {
      expect(
          PageCoverObserver.coveredByPage(shell, [shell, page, popup]), isTrue);
    });
  });

  group('over a native-bar shell', () {
    testWidgets('idle: native bar reported, no floating pill', (tester) async {
      await _pump(tester);
      expect(find.byType(CastMiniController), findsNothing);
    });

    testWidgets('a dialog hides the native bar but keeps the pill away',
        (tester) async {
      final log = await _pump(tester);
      expect(log.last, isTrue);

      await tester.tap(find.byKey(const Key('dialog')));
      await tester.pumpAndSettle();

      expect(log.last, isFalse, reason: 'native bar hides under a dialog');
      expect(find.byType(CastMiniController), findsNothing);

      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(log.last, isTrue);
      expect(find.byType(CastMiniController), findsNothing);
    });

    testWidgets('a modal bottom sheet does the same', (tester) async {
      final log = await _pump(tester);

      await tester.tap(find.byKey(const Key('sheet')));
      await tester.pumpAndSettle();

      expect(log.last, isFalse);
      expect(find.byType(CastMiniController), findsNothing);

      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(log.last, isTrue);
      expect(find.byType(CastMiniController), findsNothing);
    });

    testWidgets('a page over the shell brings the pill back', (tester) async {
      final log = await _pump(tester);

      await tester.tap(find.byKey(const Key('page')));
      await tester.pumpAndSettle();

      expect(log.last, isFalse);
      expect(find.byType(CastMiniController), findsOneWidget);

      Navigator.of(tester.element(find.text('a page'))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(CastMiniController), findsNothing);
      expect(log.last, isTrue);
    });
  });
}
