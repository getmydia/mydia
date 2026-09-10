import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/crash_reporting/crash_reporter_provider.dart';
import 'settings_row.dart';

/// Opt-in for sending crash reports to the Mydia developers.
///
/// The choice belongs to the device, not the account, and lives behind the
/// app's `CrashReporter`, so flipping it applies to the next report with no
/// restart. Built like `BetaChannelRow`: the switch moves at once, and a
/// generation counter keeps a slow first read from clobbering a tap.
///
/// The platform gate lives at the call site (`CrashReporter.isAvailable`), so
/// a `flutter test` host can still exercise the row.
class CrashReportingRow extends ConsumerStatefulWidget {
  const CrashReportingRow({super.key});

  @override
  ConsumerState<CrashReportingRow> createState() => _CrashReportingRowState();
}

class _CrashReportingRowState extends ConsumerState<CrashReportingRow> {
  bool _enabled = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = _generation;
    final enabled = await ref.read(crashReporterProvider).isEnabled();
    if (mounted && generation == _generation) {
      setState(() => _enabled = enabled);
    }
  }

  Future<void> _set(bool value) async {
    final generation = ++_generation;
    setState(() => _enabled = value);

    final reporter = ref.read(crashReporterProvider);
    try {
      await reporter.setEnabled(value);
    } catch (e) {
      debugPrint('[CrashReporter] Could not store the choice: $e');
      // The write did not land, so the optimistic value is a lie. Show what
      // the reporter actually holds.
      final actual = await reporter.isEnabled();
      if (mounted && generation == _generation) {
        setState(() => _enabled = actual);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsRow.toggle(
      key: const Key('crash-reporting-switch'),
      icon: Icons.bug_report_outlined,
      title: 'Share crashes with developers',
      subtitle: 'Sends error details, app version and platform to the Mydia '
          'developers when the app hits an error.',
      value: _enabled,
      onChanged: _set,
    );
  }
}
