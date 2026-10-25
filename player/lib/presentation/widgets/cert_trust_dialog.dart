import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/palette.dart';
import '../../l10n/l10n.dart';
import 'glass/glass_dialog.dart';
import 'toast/toaster.dart';

/// Dialog that asks the user to trust a certificate on first connection.
///
/// This implements Trust On First Use (TOFU) for self-signed certificates.
/// The dialog displays the certificate fingerprint and asks the user to
/// verify it matches what they expect.
///
/// Returns `true` if the user trusts the certificate, `false` otherwise.
class CertTrustDialog extends StatelessWidget {
  final String serverUrl;
  final String fingerprint;

  const CertTrustDialog({
    super.key,
    required this.serverUrl,
    required this.fingerprint,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return GlassDialog(
      title: Row(
        children: [
          const Icon(Icons.security, color: AppColors.warning),
          const SizedBox(width: 12),
          Text(context.l10n.certTrustTitle),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.certTrustFirstConnection,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: palette.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            serverUrl,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.certTrustSelfSigned,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: palette.border,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    fingerprint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: context.l10n.certTrustCopyFingerprint,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: fingerprint));
                    showToast(
                      context,
                      context.l10n.certTrustFingerprintCopied,
                      kind: ToastKind.success,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber,
                  color: AppColors.warning,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.l10n.certTrustWarning,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.warning,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.certTrustConfirm),
        ),
      ],
    );
  }
}

/// Shows the certificate trust dialog and returns the user's choice.
///
/// Returns `true` if the user trusts the certificate, `false` if they
/// cancel, or `null` if the dialog is dismissed.
Future<bool?> showCertTrustDialog(
  BuildContext context,
  String serverUrl,
  String fingerprint,
) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => CertTrustDialog(
      serverUrl: serverUrl,
      fingerprint: fingerprint,
    ),
  );
}
