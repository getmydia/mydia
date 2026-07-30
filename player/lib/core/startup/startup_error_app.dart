import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
  });

  /// Shown when another instance of the app is already running and holding
  /// the lock on the shared data directory. Specifically detected, so the
  /// message can be user-actionable instead of a generic error dump.
  factory StartupErrorApp.alreadyRunning(Object error) => StartupErrorApp(
        title: 'Mydia Player is already running',
        message: 'Another window of Mydia Player is already open on this '
            'computer. Quit it, then reopen this one.',
        details: '$error',
        key: const Key('startup-error-already-running'),
      );

  /// Shown for any other fatal startup failure, with whatever underlying
  /// error text is available so the user (or a bug report) has something to
  /// go on.
  factory StartupErrorApp.generic(Object error) => StartupErrorApp(
        title: "Mydia Player couldn't start",
        message: 'Something went wrong while starting the app.',
        details: '$error',
        key: const Key('startup-error-generic'),
      );

  final String title;
  final String message;
  final String? details;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mydia Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 56),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
