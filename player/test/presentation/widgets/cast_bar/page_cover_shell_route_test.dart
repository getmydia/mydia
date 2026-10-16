import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/router/page_cover_observer.dart';

// Pins `notifyRootObserver: false` on the app's ShellRoute (app_router.dart).
// go_router forwards the shell navigator's pages to the root observers by
// default, which made PageCoverObserver report the shell as covered all the
// time (macOS sidebar collapsed at launch, AppShell.nativeBarReported was
// always false on iPhone). The flat GoRouter in page_cover_test.dart has no
// ShellRoute, so it could not see that.
//
// AppShell cannot be mounted here, so `_ShellProbe` makes the same call it
// makes: `PageCoverObserver.isCovered(ModalRoute.of(context))`. The router is
// wired as in the app: the observer on the root GoRouter, a ShellRoute with
// its own navigator key, and the player as a top-level route on the root
// navigator.

class _ShellProbe extends StatefulWidget {
  const _ShellProbe({
    required this.observer,
    required this.coveredLog,
    required this.child,
  });

  final PageCoverObserver observer;
  final List<bool> coveredLog;
  final Widget child;

  @override
  State<_ShellProbe> createState() => _ShellProbeState();
}

class _ShellProbeState extends State<_ShellProbe> {
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
    widget.coveredLog.add(widget.observer.isCovered(ModalRoute.of(context)));
    return Scaffold(body: widget.child);
  }
}

class _Harness {
  _Harness(this.router, this.coveredLog);
  final GoRouter router;
  final List<bool> coveredLog;

  /// What the shell last computed for itself.
  bool get covered => coveredLog.last;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required bool notifyRootObserver,
}) async {
  final observer = PageCoverObserver();
  addTearDown(observer.dispose);
  final coveredLog = <bool>[];
  final shellKey = GlobalKey<NavigatorState>();

  final router = GoRouter(
    observers: [observer],
    routes: [
      ShellRoute(
        navigatorKey: shellKey,
        notifyRootObserver: notifyRootObserver,
        builder: (context, state, child) => _ShellProbe(
          observer: observer,
          coveredLog: coveredLog,
          child: child,
        ),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const Text('home')),
          GoRoute(path: '/movies', builder: (_, __) => const Text('movies')),
        ],
      ),
      GoRoute(path: '/player', builder: (_, __) => const Text('player')),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return _Harness(router, coveredLog);
}

void main() {
  group('ShellRoute with notifyRootObserver: false', () {
    testWidgets('a shell child is not covering the shell', (tester) async {
      final h = await _pump(tester, notifyRootObserver: false);
      expect(find.text('home'), findsOneWidget);
      expect(h.covered, isFalse);
    });

    testWidgets('moving between shell children stays uncovered',
        (tester) async {
      final h = await _pump(tester, notifyRootObserver: false);

      h.router.go('/movies');
      await tester.pumpAndSettle();
      expect(find.text('movies'), findsOneWidget);
      expect(h.covered, isFalse);

      h.router.go('/');
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(h.covered, isFalse);
    });

    testWidgets('a page over the shell covers it, popping uncovers',
        (tester) async {
      final h = await _pump(tester, notifyRootObserver: false);

      unawaited(h.router.push<void>('/player'));
      await tester.pumpAndSettle();
      expect(find.text('player'), findsOneWidget);
      expect(h.covered, isTrue);

      h.router.pop();
      await tester.pumpAndSettle();
      expect(find.text('player'), findsNothing);
      expect(h.covered, isFalse);
    });
  });

  testWidgets(
      'control: notifyRootObserver: true reports a plain shell child as '
      'covered', (tester) async {
    final h = await _pump(tester, notifyRootObserver: true);
    expect(find.text('home'), findsOneWidget);
    expect(h.covered, isTrue,
        reason: 'the bug the app fix removes: shell pages reach the root '
            'observer and look like pages over the shell');
  });
}
