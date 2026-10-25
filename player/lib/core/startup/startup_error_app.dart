import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../crash_reporting/startup_report_controller.dart';

/// Last-resort UI for when startup cannot proceed to [MyApp].
///
/// The one invariant `main()` must uphold is that `runApp` is always called,
/// on every code path. If a startup step fails badly enough that the app
/// can't reasonably continue, this is what gets run instead of leaving the
/// user staring at a black window with no explanation.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({
    super.key,
    required this.title,
    required this.message,
    this.details,
    this.report,
  });

  /// Shown when another instance of the app is already running and holding
  /// the lock on the shared data directory. Specifically detected, so the
  /// message can be user-actionable instead of a generic error dump.
  factory StartupErrorApp.alreadyRunning(Object error) => StartupErrorApp(
        title: (l10n) => l10n.startupAlreadyRunningTitle,
        message: (l10n) => l10n.startupAlreadyRunningMessage,
        details: '$error',
        key: const Key('startup-error-already-running'),
      );

  /// Shown for any other fatal startup failure, with whatever underlying
  /// error text is available so the user (or a bug report) has something to
  /// go on. [report], when given, adds a Send report button.
  factory StartupErrorApp.generic(
    Object error, {
    StartupReportController? report,
  }) =>
      StartupErrorApp(
        title: (l10n) => l10n.startupGenericTitle,
        message: (l10n) => l10n.startupGenericMessage,
        details: '$error',
        report: report,
        key: const Key('startup-error-generic'),
      );

  /// Selectors rather than text: the factories run before any
  /// [Localizations] exists, so the strings are looked up in [build].
  final String Function(AppLocalizations) title;
  final String Function(AppLocalizations) message;

  /// Raw error text, shown as is.
  final String? details;

  /// Drives the Send report button. Null hides it: on web, where nothing is
  /// sent, and on the already-running screen, which is not a crash.
  final StartupReportController? report;

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    return MaterialApp(
      title: 'Mydia Player', // l10n-ignore: product name
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      // Follows the device locale: no settings exist yet at this point.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // This widget's own context sits above Localizations.
      home: Builder(builder: (context) => _buildBody(context.l10n, report)),
    );
  }

  Widget _buildBody(AppLocalizations l10n, StartupReportController? report) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 56),
              const SizedBox(height: 16),
              Text(
                title(l10n),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message(l10n),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              if (details != null) ...[
                const SizedBox(height: 24),
                SelectableText(
                  details!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                  ),
                ),
              ],
              if (report != null) ...[
                const SizedBox(height: 24),
                _SendReportButton(controller: report),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One button whose label and enabled state follow the controller.
class _SendReportButton extends StatelessWidget {
  const _SendReportButton({required this.controller});

  final StartupReportController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<StartupReportState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final l10n = context.l10n;
        final (icon, label, onPressed) = switch (state) {
          StartupReportState.idle => (
              const Icon(Icons.send_outlined),
              l10n.startupSendReport,
              controller.send,
            ),
          StartupReportState.sending => (
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              l10n.startupSendingReport,
              null,
            ),
          StartupReportState.sent => (
              const Icon(Icons.check),
              l10n.startupReportSent,
              null,
            ),
          StartupReportState.failed => (
              const Icon(Icons.refresh),
              l10n.startupReportFailed,
              controller.send,
            ),
        };
        return OutlinedButton.icon(
          key: const Key('startup-report-button'),
          onPressed: onPressed,
          icon: icon,
          label: Text(label),
        );
      },
    );
  }
}
