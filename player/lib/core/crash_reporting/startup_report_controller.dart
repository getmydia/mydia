import 'package:flutter/foundation.dart';

enum StartupReportState { idle, sending, sent, failed }

/// Drives the Send report button on the startup-error screen.
///
/// Each [send] is one POST: no queue, no throttle, no dedup. A tap is the
/// consent, the way an admin's manual report is on the server.
class StartupReportController extends ValueNotifier<StartupReportState> {
  StartupReportController({
    required Future<bool> Function({required bool manual}) send,
  })  : _send = send,
        super(StartupReportState.idle);

  final Future<bool> Function({required bool manual}) _send;

  /// Sends the report unless one is in flight or already delivered.
  ///
  /// [manual] is true for a tap and false when the reporter sends on its own
  /// because the user opted in earlier.
  Future<void> send({bool manual = true}) async {
    if (value == StartupReportState.sending ||
        value == StartupReportState.sent) {
      return;
    }
    value = StartupReportState.sending;
    final delivered = await _send(manual: manual);
    value = delivered ? StartupReportState.sent : StartupReportState.failed;
  }
}
