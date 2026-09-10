import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'crash_reporter.dart';

/// The app's [CrashReporter].
///
/// `main()` overrides this with the reporter it installed. Anything running
/// without that override, such as the widget and integration tests that pump
/// `MyApp` directly, gets an inert reporter that sends nothing, the way
/// `fetchLogProvider` falls back to an in-memory log.
final Provider<CrashReporter> crashReporterProvider =
    Provider<CrashReporter>((ref) => CrashReporter.inert());
