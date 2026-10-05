/// Where every locked or hidden source, and "Show hidden sources", lands.
/// Never names a source: the same screen for a locked one, a hidden one and
/// a device with nothing hidden at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/root_routes.dart';
import '../../../core/sources/lock/device_auth.dart';
import '../../../core/sources/lock/pin_store.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/sources_providers.dart';
import '../../widgets/toast/toaster.dart';
import 'pin_pad.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key, this.next});

  /// An in-app location to continue to. Anything else goes home. Without
  /// one, the screen returns to whatever opened it.
  final String? next;

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  bool _deviceAvailable = false;
  bool _showPin = false;
  bool _prompting = false;

  String get _next {
    final next = widget.next;
    if (next == null ||
        !next.startsWith('/') ||
        next.startsWith('//') ||
        next.startsWith('/unlock') ||
        next.contains(r'\')) {
      return '/';
    }
    return next;
  }

  /// Back to whatever opened this screen, or home when nothing did.
  void _leave() => context.canPop() ? context.pop() : context.go('/');

  /// After unlocking. Without a `next`, the opener is the destination. A
  /// root-navigator `next` replaces this screen, keeping the opener under it
  /// for the destination's back button: a `go` there leaves iOS, which has no
  /// system back, with no way out. A shell `next` has the shell's nav, so it
  /// is a `go`.
  void _continue() {
    if (widget.next == null) {
      _leave();
    } else if (opensOverShell(_next) && context.canPop()) {
      context.pushReplacement(_next);
    } else {
      context.go(_next);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final available = await ref.read(deviceAuthProvider).available();
    if (!mounted) return;
    setState(() {
      _deviceAvailable = available;
      _showPin = !available;
    });
    if (available) await _tryDevice();
  }

  Future<void> _tryDevice() async {
    if (_prompting) return;
    setState(() => _prompting = true);
    final result =
        await ref.read(sourceLockProvider.notifier).unlockWithDevice();
    if (!mounted) return;
    setState(() => _prompting = false);
    switch (result) {
      case DeviceAuthResult.success:
        _continue();
      case DeviceAuthResult.unavailable:
        setState(() {
          _deviceAvailable = false;
          _showPin = true;
        });
      case DeviceAuthResult.failed:
        Toaster.of(context).show('Could not unlock. Try again or use your PIN.',
            kind: ToastKind.error);
      case DeviceAuthResult.cancelled:
        break;
    }
  }

  Future<String?> _tryPin(String pin) async {
    final result =
        await ref.read(sourceLockProvider.notifier).unlockWithPin(pin);
    if (!mounted) return null;
    switch (result) {
      case PinAccepted():
        _continue();
        return null;
      case PinRejected():
        return 'Wrong PIN.';
      case PinBlocked(:final until):
        final seconds = until.difference(DateTime.now()).inSeconds + 1;
        return 'Too many tries. Wait $seconds seconds.';
    }
  }

  Future<void> _forgotPin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forgot your PIN?'),
        content: const Text('Every server you locked or hid is removed from '
            'this device, and the PIN is deleted. Nothing changes on the '
            'servers; add them again to use them.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('unlock-forgot-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove them'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final toaster = Toaster.of(context);
    try {
      await ref.read(sourceRecordsProvider.notifier).removeLockedAccounts();
      await ref.read(pinStoreProvider).clear();
    } catch (_) {
      toaster.show('Could not remove them.', kind: ToastKind.error);
      return;
    }
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_rounded, size: 48),
                const SizedBox(height: 16),
                Text('Unlock',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                    'Locked and hidden servers open until the app '
                    'has been in the background for a minute.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (_showPin)
                  PinPad(onSubmit: _tryPin)
                else if (_deviceAvailable)
                  FilledButton.icon(
                    key: const Key('unlock-retry-device'),
                    onPressed: _prompting ? null : _tryDevice,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('Unlock'),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (_deviceAvailable && !_showPin)
                      TextButton(
                        key: const Key('unlock-use-pin'),
                        onPressed: () => setState(() => _showPin = true),
                        child: const Text('Use PIN'),
                      ),
                    if (_showPin)
                      TextButton(
                        key: const Key('unlock-forgot-pin'),
                        onPressed: _forgotPin,
                        child: const Text('Forgot PIN'),
                      ),
                    TextButton(
                      key: const Key('unlock-cancel'),
                      onPressed: _leave,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
