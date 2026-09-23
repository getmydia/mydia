import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/startup/startup_gate.dart';
import 'package:player/core/startup/startup_init.dart';

void main() {
  testWidgets('paints the splash before init finishes, then the app',
      (tester) async {
    final startup = Completer<StartupOutcome>();
    await tester.pumpWidget(StartupGate(
      startup: startup.future,
      buildApp: (_) => const MaterialApp(home: Text('app')),
      buildFailure: (_) => const MaterialApp(home: Text('failed')),
    ));
    expect(find.byKey(const Key('startup-splash')), findsOneWidget);
    expect(find.text('app'), findsNothing);

    startup.complete(StartupReady(
      fetchLog: InMemoryFetchLog(),
      sidebarLayoutStore: InMemorySidebarLayoutStore(),
      initialConnection: null,
    ));
    // Not pumpAndSettle: the splash's CircularProgressIndicator animates
    // forever, so pumpAndSettle never sees the frame count settle. One pump
    // lets the completed future's `.then` fire and call setState; the next
    // draws the frame with the swapped-in app.
    await tester.pump();
    await tester.pump();
    expect(find.text('app'), findsOneWidget);
    expect(find.byKey(const Key('startup-splash')), findsNothing);
  });

  testWidgets('renders the failure app for a failed startup', (tester) async {
    await tester.pumpWidget(StartupGate(
      startup: Future.value(StartupAlreadyRunning(StateError('locked'))),
      buildApp: (_) => const MaterialApp(home: Text('app')),
      buildFailure: (_) => const MaterialApp(home: Text('failed')),
    ));
    // See the note above: pumpAndSettle hangs on the splash's indefinite
    // spinner animation.
    await tester.pump();
    await tester.pump();
    expect(find.text('failed'), findsOneWidget);
  });
}
