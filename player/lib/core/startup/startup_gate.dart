import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'startup_init.dart';

/// The first thing `main()` hands to `runApp`, so the window paints on the
/// first frame instead of staying black while startup runs.
///
/// Swaps itself for [buildApp] or [buildFailure] once [startup] settles. That
/// swap is what keeps `_startApp`'s "runApp exactly once" invariant: the
/// error screens that used to be separate `runApp` calls are now children.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.startup,
    required this.buildApp,
    required this.buildFailure,
  });

  final Future<StartupOutcome> startup;
  final Widget Function(StartupReady ready) buildApp;
  final Widget Function(StartupOutcome failure) buildFailure;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  StartupOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    widget.startup.then(
      (outcome) {
        if (mounted) setState(() => _outcome = outcome);
      },
      // `runStartup` guards its own steps with try/catch, but a rejection
      // straight from the `startup` future itself -- an unexpected throw
      // from a step it does not wrap, such as `inputCapabilities()` or
      // `sidebarLayoutStore()` -- has no `then` handler above to catch it.
      // Without this, the splash stays up forever instead of swapping to a
      // failure screen.
      onError: (Object error, StackTrace stackTrace) {
        if (mounted) {
          setState(() => _outcome = StartupFailed(error, stackTrace));
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => switch (_outcome) {
        null => const StartupSplash(),
        final StartupReady ready => widget.buildApp(ready),
        final other => widget.buildFailure(other),
      };
}

/// The `Scaffold` painting the theme's background is what ends the black
/// screen; the spinner is secondary. Deliberately asset-free: decoding an
/// image on the very first frame works against the point of a splash that
/// exists to paint *something* as fast as possible.
class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        key: Key('startup-splash'),
        body: Center(
          child: SizedBox.square(
            dimension: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
      ),
    );
  }
}
