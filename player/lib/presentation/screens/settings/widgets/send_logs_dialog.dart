import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/logging/log_uploader.dart';
import '../../../../core/player/input_capabilities.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/focus_highlight.dart';
import '../../../widgets/toast/toaster.dart';
import '../../../widgets/glass/glass_dialog.dart';

/// Asks for an optional note, sends this device's logs once, and shows the
/// report code to quote, or what went wrong with a way to try again.
Future<void> showSendLogsDialog(
  BuildContext context, {
  required Future<String> Function(String? note) send,
}) =>
    showDialog<void>(
      context: context,
      // A tap outside must not drop an in-flight upload: the code the relay
      // hands back would be lost, and the user's next move would be to send
      // the same logs again. See the PopScope in build() for the back-press
      // equivalent.
      barrierDismissible: false,
      builder: (_) => SendLogsDialog(send: send),
    );

class SendLogsDialog extends StatefulWidget {
  const SendLogsDialog({
    super.key,
    required this.send,
    this.directionalPrimary,
  });

  final Future<String> Function(String? note) send;

  /// Whether the viewer drives the app with a D-pad. Null reads
  /// [InputCapabilities.directionalPrimary]; tests pass a value.
  ///
  /// On a remote the note field cannot be a permanent focus target: focusing
  /// it raises the keyboard, and Back/Select then reach the dialog route and
  /// close it. So the note shows as a row and the field only exists while it
  /// is being edited.
  final bool? directionalPrimary;

  @override
  State<SendLogsDialog> createState() => _SendLogsDialogState();
}

enum _Phase { editing, sending, sent, failed }

class _SendLogsDialogState extends State<SendLogsDialog> {
  final _note = TextEditingController();
  final _noteRowFocus = FocusNode(debugLabel: 'send-logs-note-row');
  bool _editingNote = false;
  _Phase _phase = _Phase.editing;
  String? _code;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    _noteRowFocus.dispose();
    super.dispose();
  }

  bool get _tv =>
      widget.directionalPrimary ?? InputCapabilities.directionalPrimary;

  void _startEditingNote() => setState(() => _editingNote = true);

  /// Back to the note row, and hand focus back to it: the row is rebuilt from
  /// scratch, so without this the focus lands wherever the traversal policy
  /// picks.
  void _stopEditingNote() {
    setState(() => _editingNote = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _noteRowFocus.requestFocus();
    });
  }

  Widget _noteField() => TextField(
        key: const Key('diagnostics-send-logs-note'),
        controller: _note,
        maxLength: 2000,
        maxLines: _tv ? 1 : 3,
        autofocus: _tv,
        textInputAction: _tv ? TextInputAction.done : null,
        onSubmitted: _tv ? (_) => _stopEditingNote() : null,
        decoration: InputDecoration(
          labelText: context.l10n.settingsDiagnosticsNoteLabel,
        ),
      );

  Widget _noteRow() {
    final note = _note.text.trim();
    return FocusHighlight(
      key: const Key('diagnostics-send-logs-note-row'),
      focusNode: _noteRowFocus,
      onActivate: _startEditingNote,
      child: InkWell(
        // FocusHighlight owns the row's focus; this only takes pointer taps.
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(8),
        onTap: _startEditingNote,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.edit_outlined, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  note.isEmpty
                      ? context.l10n.settingsDiagnosticsNoteEmpty
                      : note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
            ? context.l10n.logUploadFailure(e)
            : context.l10n.settingsDiagnosticsRelayUnreachable;
      });
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _code!));
    if (!mounted) return;
    showToast(
      context,
      context.l10n.settingsDiagnosticsCodeCopied,
      kind: ToastKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final editingNote = _phase == _Phase.editing && _editingNote;
    final l10n = context.l10n;
    return PopScope(
      // Blocked while sending: once the code or the error is on screen, Done,
      // Close and Retry are how this closes, and a back press should work
      // like any other dialog. Also blocked while the note field is up on a
      // remote, where Back leaves the field instead of closing the dialog.
      canPop: _phase != _Phase.sending && !editingNote,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && editingNote) _stopEditingNote();
      },
      child: GlassDialog(
        title: Text(l10n.settingsDiagnosticsSendLogsTitle),
        content: switch (_phase) {
          _Phase.editing => _tv && !_editingNote ? _noteRow() : _noteField(),
          _Phase.sending => const SizedBox(
              height: 48,
              child: Center(child: CircularProgressIndicator()),
            ),
          _Phase.sent => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsDiagnosticsShareCode),
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
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                key: const Key('diagnostics-send-logs-confirm'),
                // Focused on open regardless of what GlassDialog's own
                // fallback does, so a remote press lands on Send.
                autofocus: true,
                onPressed: _send,
                child: Text(l10n.commonSend),
              ),
            ],
          _Phase.sending => const <Widget>[],
          _Phase.sent => [
              TextButton(
                key: const Key('diagnostics-report-copy'),
                onPressed: _copy,
                child: Text(l10n.commonCopy),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonDone),
              ),
            ],
          _Phase.failed => [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonClose),
              ),
              FilledButton(
                key: const Key('diagnostics-report-retry'),
                onPressed: _send,
                child: Text(l10n.commonRetry),
              ),
            ],
        },
      ),
    );
  }
}
