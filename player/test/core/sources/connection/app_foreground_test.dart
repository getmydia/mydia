import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/connection/app_foreground.dart';

void main() {
  test('starts_in_the_foreground_with_no_departures', () async {
    final app = AppForeground();
    expect(app.foreground, isTrue);
    expect(app.departures, 0);
    await app.whenForeground();
  });

  test('hiding_counts_one_departure_until_the_app_resumes', () {
    final app = AppForeground()
      ..onLifecycle(AppLifecycleState.inactive)
      ..onLifecycle(AppLifecycleState.hidden)
      ..onLifecycle(AppLifecycleState.paused);
    expect(app.foreground, isFalse);
    expect(app.departures, 1);

    app
      ..onLifecycle(AppLifecycleState.hidden)
      ..onLifecycle(AppLifecycleState.inactive)
      ..onLifecycle(AppLifecycleState.resumed)
      ..onLifecycle(AppLifecycleState.inactive)
      ..onLifecycle(AppLifecycleState.hidden);
    expect(app.departures, 2);
  });

  test('inactive_alone_is_not_a_departure', () {
    // Control Center or a system sheet over the app: it keeps running.
    final app = AppForeground()..onLifecycle(AppLifecycleState.inactive);
    expect(app.foreground, isTrue);
    expect(app.departures, 0);
  });

  test('when_foreground_waits_for_the_resume', () async {
    final app = AppForeground()..onLifecycle(AppLifecycleState.paused);
    var back = false;
    final waiting = app.whenForeground().then((_) => back = true);
    await pumpEventQueue();
    expect(back, isFalse);

    app.onLifecycle(AppLifecycleState.resumed);
    await waiting;
    expect(back, isTrue);
  });
}
