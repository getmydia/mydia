import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crash_reporting/startup_report_controller.dart';

void main() {
  test('goes idle, sending, sent', () async {
    final gate = Completer<bool>();
    final controller = StartupReportController(
      send: ({required bool manual}) => gate.future,
    );
    expect(controller.value, StartupReportState.idle);

    final sending = controller.send();
    expect(controller.value, StartupReportState.sending);

    gate.complete(true);
    await sending;
    expect(controller.value, StartupReportState.sent);
  });

  test('passes manual through, defaulting to true for a tap', () async {
    final seen = <bool>[];
    final controller = StartupReportController(
      send: ({required bool manual}) async {
        seen.add(manual);
        return false;
      },
    );

    await controller.send(manual: false);
    await controller.send();

    expect(seen, [false, true]);
  });

  test('ignores a second send while one is in flight', () async {
    final gate = Completer<bool>();
    var calls = 0;
    final controller = StartupReportController(
      send: ({required bool manual}) {
        calls++;
        return gate.future;
      },
    );

    final first = controller.send();
    await controller.send();
    gate.complete(true);
    await first;

    expect(calls, 1);
  });

  test('ignores send once the report is sent', () async {
    var calls = 0;
    final controller = StartupReportController(
      send: ({required bool manual}) async {
        calls++;
        return true;
      },
    );

    await controller.send();
    await controller.send();

    expect(calls, 1);
  });

  test('a failed send can be retried', () async {
    final results = [false, true];
    final controller = StartupReportController(
      send: ({required bool manual}) async => results.removeAt(0),
    );

    await controller.send();
    expect(controller.value, StartupReportState.failed);

    await controller.send();
    expect(controller.value, StartupReportState.sent);
  });
}
