/// Signing in to Google for the Drive backup: the platform's own sign-in
/// on phones and desktops, and on a TV a sheet with a code to enter on a
/// phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/backup/backup_providers.dart';
import '../../../core/backup/backup_relay_client.dart';
import '../../../core/backup/cloud/google_auth.dart';
import '../../../core/backup/cloud/google_oauth_flows.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/toast/toaster.dart';

/// How this device signs in to Google: [signIn] runs a sign-in that needs
/// no UI of ours (the system sheet, or the browser and a loopback
/// redirect), [deviceCode] starts the TV's device code flow. Exactly one is
/// set.
class GoogleSignInMethod {
  const GoogleSignInMethod({
    required this.currentEmail,
    this.signIn,
    this.deviceCode,
  }) : assert((signIn == null) != (deviceCode == null));

  /// The signed-in account, null when signed out.
  final Future<String?> Function() currentEmail;

  final Future<void> Function()? signIn;
  final Stream<DeviceCodeState> Function()? deviceCode;
}

/// The sign-in for [auth], the way `googleAuthForPlatform` chose it.
GoogleSignInMethod? googleSignInMethodFor(GoogleAuth? auth) => switch (auth) {
  null => null,
  final GoogleSignInAuth a => GoogleSignInMethod(
    currentEmail: a.currentEmail,
    signIn: a.signIn,
  ),
  final GoogleTokenAuth a when a.clientKind == 'tv' => GoogleSignInMethod(
    currentEmail: a.currentEmail,
    deviceCode: () => DeviceCodeFlow().signIn(a),
  ),
  final GoogleTokenAuth a => GoogleSignInMethod(
    currentEmail: a.currentEmail,
    signIn: () => LoopbackPkceFlow().signIn(a),
  ),
  _ => null,
};

/// This device's Google sign-in, null where Drive is not offered.
final Provider<GoogleSignInMethod?> googleSignInMethodProvider =
    Provider<GoogleSignInMethod?>(
      (ref) =>
          googleSignInMethodFor(ref.watch(backupControllerProvider).googleAuth),
    );

/// Signs in to Google unless already signed in ([force] signs in
/// regardless, for an account whose access was revoked). True once signed
/// in. A sign-in the viewer declined or abandoned is not an error; any
/// other failure is toasted. Sign-in failures never read as an unavailable
/// store.
bool _sameGoogleAccount(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

Future<bool> signInToGoogle(
  BuildContext context,
  GoogleSignInMethod? method, {
  bool force = false,
  String? expectedAccount,
}) async {
  if (method == null) return false;
  final expected = expectedAccount?.trim();
  final wantAccount = (expected == null || expected.isEmpty) ? null : expected;
  final l10n = context.l10n;
  final toaster = Toaster.of(context);
  final failed = l10n.backupActionFailed;
  final scopeMissing = l10n.backupGoogleScopeMissing;
  try {
    final current = force ? null : await method.currentEmail();
    if (current != null &&
        (wantAccount == null || _sameGoogleAccount(current, wantAccount))) {
      return true;
    }
    var signedIn = false;
    final signIn = method.signIn;
    if (signIn != null) {
      await signIn();
      signedIn = true;
    } else {
      if (!context.mounted) return false;
      signedIn = await showGoogleDeviceCodeSheet(context, method.deviceCode!);
    }
    if (!signedIn) return false;
    if (wantAccount != null) {
      final actual = await method.currentEmail();
      if (actual == null) {
        toaster.show(failed, kind: ToastKind.error);
        return false;
      }
      if (!_sameGoogleAccount(actual, wantAccount)) {
        toaster.show(
          l10n.backupGoogleAccountMismatch(actual, wantAccount),
          kind: ToastKind.error,
        );
        return false;
      }
    }
    return true;
  } on BackupRelayException catch (e) {
    if (e.code == googleScopeMissingCode) {
      toaster.show(scopeMissing, kind: ToastKind.error);
    } else if (e.kind != BackupRelayError.signedOut) {
      toaster.show(failed, kind: ToastKind.error);
    }
    debugPrint('[Backup] Google sign-in failed: ${e.kind.name}');
    return false;
  } catch (e) {
    debugPrint('[Backup] Google sign-in failed: ${e.runtimeType}');
    toaster.show(failed, kind: ToastKind.error);
    return false;
  }
}

/// Shows the code [start]'s flow hands out until the viewer enters it on
/// another device. True once signed in; false when declined, cancelled or
/// failed (a failure is toasted). An expired code can be replaced.
Future<bool> showGoogleDeviceCodeSheet(
  BuildContext context,
  Stream<DeviceCodeState> Function() start,
) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => GlassDialog(
      content: SizedBox(width: 460, child: GoogleDeviceCodeSheet(start: start)),
    ),
  );
  return done ?? false;
}

class GoogleDeviceCodeSheet extends StatefulWidget {
  const GoogleDeviceCodeSheet({super.key, required this.start});

  /// Starts one device code flow; called again for each new code.
  final Stream<DeviceCodeState> Function() start;

  @override
  State<GoogleDeviceCodeSheet> createState() => _GoogleDeviceCodeSheetState();
}

class _GoogleDeviceCodeSheetState extends State<GoogleDeviceCodeSheet> {
  StreamSubscription<DeviceCodeState>? _sub;
  DeviceCodePending? _pending;
  bool _expired = false;
  bool _closing = false;
  final _retryFocus = FocusNode(debugLabel: 'google-device-code-retry');

  @override
  void initState() {
    super.initState();
    _sub = widget.start().listen(_onState, onError: _onError);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _retryFocus.dispose();
    super.dispose();
  }

  /// A new code, after the last one expired.
  void _retry() {
    unawaited(_sub?.cancel());
    setState(() {
      _pending = null;
      _expired = false;
    });
    _sub = widget.start().listen(_onState, onError: _onError);
  }

  void _stopListening() {
    _closing = true;
    unawaited(_sub?.cancel());
    _sub = null;
  }

  void _close(bool result) {
    if (_closing || !mounted) return;
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    _stopListening();
    if (isCurrent) Navigator.of(context).pop(result);
  }

  void _onState(DeviceCodeState state) {
    if (!mounted || _closing || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    switch (state) {
      case final DeviceCodePending p:
        setState(() => _pending = p);
      case DeviceCodeDone():
        _close(true);
      case DeviceCodeDenied():
        _close(false);
      case DeviceCodeExpired():
        setState(() {
          _pending = null;
          _expired = true;
        });
        // The retry replaces the code the viewer was looking at: on a TV,
        // OK should land on it.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_closing && _expired) _retryFocus.requestFocus();
        });
    }
  }

  void _onError(Object e) {
    debugPrint('[Backup] Google device code sign-in failed: ${e.runtimeType}');
    if (!mounted || _closing || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final l10n = context.l10n;
    showToast(
      context,
      e is BackupRelayException && e.code == googleScopeMissingCode
          ? l10n.backupGoogleScopeMissing
          : l10n.backupActionFailed,
      kind: ToastKind.error,
    );
    _close(false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final pending = _pending;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _stopListening();
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.googleDeviceCodeTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (_expired)
              Text(
                l10n.googleDeviceCodeExpired,
                key: const Key('google-device-code-expired'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else if (pending == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              Text(
                l10n.googleDeviceCodeBody(pending.verificationUrl.toString()),
                style: TextStyle(color: palette.textSecondary),
              ),
              const SizedBox(height: 16),
              SelectableText(
                pending.userCode,
                key: const Key('google-device-code'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: QrImageView(
                  key: const Key('google-device-code-qr'),
                  data: pending.verificationUrl.toString(),
                  size: 160,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // Nothing to type here: on a TV focus waits on Cancel.
                TextButton(
                  key: const Key('google-device-code-cancel'),
                  autofocus: true,
                  onPressed: () => _close(false),
                  child: Text(l10n.commonCancel),
                ),
                if (_expired) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('google-device-code-retry'),
                    focusNode: _retryFocus,
                    onPressed: _retry,
                    child: Text(l10n.commonTryAgain),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
