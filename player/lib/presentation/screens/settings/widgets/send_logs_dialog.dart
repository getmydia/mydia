import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/logging/log_uploader.dart';
import '../../../widgets/toast/toaster.dart';

/// Asks for an optional note, sends this device's logs once, and shows the
/// report code to quote, or what went wrong with a way to try again.
Future<void> showSendLogsDialog(
  BuildContext context, {
  required Future<String> Function(String? note) send,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => SendLogsDialog(send: send),
    );

class SendLogsDialog extends StatefulWidget {
  const SendLogsDialog({super.key, required this.send});

  final Future<String> Function(String? note) send;

  @override
  State<SendLogsDialog> createState() => _SendLogsDialogState();
}

enum _Phase { editing, sending, sent, failed }

class _SendLogsDialogState extends State<SendLogsDialog> {
  final _note = TextEditingController();
  _Phase _phase = _Phase.editing;
  String? _code;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    final note = _note.text.trim();
    try {
      final code = await widget.send(note.isEmpty ? null : note);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.sent;
        _code = code;
      });
    } catch (e) {
      debugPrint('[Diagnostics] Sending logs failed: $e');
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e is LogUploadException
            ? e.message
            : 'Could not reach the relay. Check the connection and try again.';
      });
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _code!));
    if (!mounted) return;
    showToast(context, 'Code copied', kind: ToastKind.success);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Send logs'),
      content: switch (_phase) {
        _Phase.editing => TextField(
            key: const Key('diagnostics-send-logs-note'),
            controller: _note,
            maxLength: 2000,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What went wrong? (optional)',
            ),
          ),
        _Phase.sending => const SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator()),
          ),
        _Phase.sent => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Share this code with the Mydia developers:'),
              const SizedBox(height: 8),
              SelectableText(
                _code!,
                key: const Key('diagnostics-report-code'),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        _Phase.failed =>
          Text(_error!, key: const Key('diagnostics-report-error')),
      },
      actions: switch (_phase) {
        _Phase.editing => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('diagnostics-send-logs-confirm'),
              onPressed: _send,
              child: const Text('Send'),
            ),
          ],
        _Phase.sending => const <Widget>[],
        _Phase.sent => [
            TextButton(
              key: const Key('diagnostics-report-copy'),
              onPressed: _copy,
              child: const Text('Copy'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        _Phase.failed => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            FilledButton(
              key: const Key('diagnostics-report-retry'),
              onPressed: _send,
              child: const Text('Retry'),
            ),
          ],
      },
    );
  }
}
