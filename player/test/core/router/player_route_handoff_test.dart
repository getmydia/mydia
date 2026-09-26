// What happens to the player page when `_navigateToEpisode` calls
// `context.go` on a player that was opened with `context.push`?
//
// The pushed page is keyed per push, the declarative one by route pattern,
// so the keys differ and the Navigator builds a new page: a new State. The
// new State's initState runs first; the old one is disposed only after its
// exit transition. `PlayerWindowSession` depends on exactly this, so if a
// go_router upgrade changes it, this test says so before users do.
//
// That is only the first advance. Once the player is on a declarative
// location, every later `go` matches the same route pattern, so the page key
// does not change and the Navigator reuses the existing State instead of
// building a new one -- it only gets `didUpdateWidget`. `_switchToFile` is
// what handles that reuse; the second test below pins it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Probe extends StatefulWidget {
  const _Probe(this.id, this.log);
  final String id;
  final List<String> log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  late final String _bornAs = widget.id;

  @override
  void initState() {
    super.initState();
    widget.log.add('init ${widget.id}');
  }

  @override
  void didUpdateWidget(_Probe oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.log.add('update ${oldWidget.id}->${widget.id}');
  }

  @override
  void dispose() {
    widget.log.add('dispose $_bornAs');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}

void main() {
  testWidgets(
      'going to the next episode builds a new player State before '
      'disposing the old one', (tester) async {
    final log = <String>[];
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Text('home')),
        GoRoute(
          path: '/player/:type/:id',
          builder: (_, state) => _Probe(state.pathParameters['id']!, log),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/player/episode/first');
    await tester.pumpAndSettle();

    router.go('/player/episode/second');
    await tester.pump();
    log.add('frame');
    await tester.pumpAndSettle();

    expect(log, ['init first', 'init second', 'frame', 'dispose first']);
  });

  testWidgets(
      'a later episode advance reuses the State instead of replacing it',
      (tester) async {
    final log = <String>[];
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Text('home')),
        GoRoute(
          path: '/player/:type/:id',
          builder: (_, state) => _Probe(state.pathParameters['id']!, log),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/player/episode/first');
    await tester.pumpAndSettle();

    router.go('/player/episode/second');
    await tester.pumpAndSettle();
    log.clear();

    router.go('/player/episode/third');
    await tester.pump();
    log.add('frame');
    await tester.pumpAndSettle();

    // No init/dispose: the second State survives and is handed `third` as
    // a widget update, unlike the first advance above.
    expect(log, ['update second->third', 'frame']);
  });
}
