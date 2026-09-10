import 'package:stack_trace/stack_trace.dart';

/// Where a report was captured. [wireName] is what the relay stores in
/// `metadata.capture`.
enum CrashCapture {
  flutterError('flutter_error'),
  zone('zone'),
  platformDispatcher('platform_dispatcher'),
  startup('startup');

  const CrashCapture(this.wireName);

  final String wireName;
}

/// Facts about this install that every report carries.
class CrashAppContext {
  const CrashAppContext({
    required this.version,
    required this.buildNumber,
    required this.platform,
    required this.osVersion,
    required this.environment,
  });

  final String version;
  final String buildNumber;
  final String platform;
  final String osVersion;

  /// `prod`, `profile` or `dev`.
  final String environment;
}

/// One stack frame, in the `{function, file, line}` shape both relays parse.
class CrashFrame {
  const CrashFrame({
    required this.function,
    required this.file,
    required this.line,
  });

  final String function;

  /// The library URI, `package:player/...` for the player's own code. It
  /// holds no local filesystem path and is the same on every machine.
  final String file;

  final int line;

  Map<String, Object?> toJson() =>
      {'function': function, 'file': file, 'line': line};
}

/// Most frames sent, matching relay-worker's `MAX_STACK_FRAMES`.
const int kMaxCrashFrames = 64;

const _appPackage = 'package:player/';

/// Parses [stack] into frames the relays can group on.
///
/// Frames without a line number (the VM's `...` fold, anything unparseable)
/// are dropped, because both relays discard an entry missing `line`. The
/// leading run of frames outside the player's own package is dropped too:
/// both relays fingerprint on frame 0, and a Flutter framework frame there
/// would merge unrelated crashes into one group. A trace with no player frame
/// at all is kept whole.
List<CrashFrame> parseCrashFrames(StackTrace? stack) {
  if (stack == null) return const [];

  final frames = [
    for (final frame in Trace.from(stack).frames)
      if (frame.line case final line?)
        CrashFrame(
          function: frame.member ?? '<unknown>',
          file: frame.library,
          line: line,
        ),
  ];

  final firstApp = frames.indexWhere((f) => f.file.startsWith(_appPackage));
  final fromApp = firstApp > 0 ? frames.sublist(firstApp) : frames;
  return fromApp.length > kMaxCrashFrames
      ? fromApp.sublist(0, kMaxCrashFrames)
      : fromApp;
}

/// One crash, ready to serialize.
class CrashReport {
  const CrashReport({
    required this.errorType,
    required this.errorMessage,
    required this.frames,
    required this.capture,
    required this.context,
    required this.occurredAt,
    this.manual = false,
  });

  factory CrashReport.fromError(
    Object error,
    StackTrace? stack, {
    required CrashCapture capture,
    required CrashAppContext context,
    required DateTime occurredAt,
    bool manual = false,
  }) {
    return CrashReport(
      errorType: error.runtimeType.toString(),
      errorMessage: error.toString(),
      frames: parseCrashFrames(stack),
      capture: capture,
      context: context,
      occurredAt: occurredAt,
      manual: manual,
    );
  }

  final String errorType;
  final String errorMessage;
  final List<CrashFrame> frames;
  final CrashCapture capture;
  final CrashAppContext context;
  final DateTime occurredAt;

  /// True only when the user tapped Send report on the startup-error screen.
  final bool manual;

  /// The request body, unsanitized. It must go through `sanitizeReport`
  /// before it leaves the device.
  Map<String, Object?> toJson() {
    final top = frames.isEmpty ? null : frames.first;
    return {
      'source': 'player',
      'error_type': errorType,
      'error_message': errorMessage,
      'stacktrace': [for (final frame in frames) frame.toJson()],
      'version': context.version,
      'environment': context.environment,
      'occurred_at': occurredAt.toUtc().toIso8601String(),
      'metadata': {
        'capture': capture.wireName,
        'manual': manual,
        'platform': context.platform,
        'os_version': context.osVersion,
        'build_number': context.buildNumber,
        // Repeats the top frame, as the server does: both relays build a
        // frame from these when `stacktrace` is empty.
        if (top != null) ...top.toJson(),
      },
    };
  }
}

/// The key a session dedups reports on: the error type plus the top frame's
/// file and line, or plus the first 200 characters of the message when there
/// is no frame. Takes the sanitized body, so the key never holds a secret.
String crashDedupKey(Map<String, Object?> body) {
  final type = body['error_type'];
  final frames = body['stacktrace'];
  if (frames is List && frames.isNotEmpty) {
    final top = frames.first;
    if (top is Map) return '$type|${top['file']}|${top['line']}';
  }
  final message = body['error_message'];
  final text = message is String ? message : '';
  return '$type|${text.length > 200 ? text.substring(0, 200) : text}';
}
