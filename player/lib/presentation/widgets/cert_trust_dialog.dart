import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/colors.dart';
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
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.security, color: AppColors.warning),
          SizedBox(width: 12),
          Text('Trust Certificate?'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'First-time connection to:',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
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
            'This server is using a self-signed certificate. '
            'Please verify the certificate fingerprint matches what you expect:',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.border,
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
                  tooltip: 'Copy fingerprint',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: fingerprint));
                    showToast(
                      context,
                      'Fingerprint copied to clipboard',
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
                    'Only trust this certificate if you control this server '
                    'and can verify the fingerprint.',
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Trust'),
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
