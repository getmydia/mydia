/// Asks for a Plex Home user's 4-digit PIN with an on-screen keypad that
/// works the same with touch, mouse and a TV remote, and also takes digits
/// from a hardware keyboard.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// True once [submit] accepted a PIN, false when the viewer cancelled.
/// [submit] answers null when the PIN worked, or the message to show; on a
/// message the digits clear and the dialog stays open.
Future<bool> showPlexPinDialog(
  BuildContext context, {
  required String userName,
  required Future<String?> Function(String pin) submit,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _PlexPinDialog(userName: userName, submit: submit),
    ) ??
    false;

class _PlexPinDialog extends StatefulWidget {
  const _PlexPinDialog({required this.userName, required this.submit});

  final String userName;
  final Future<String?> Function(String pin) submit;

  @override
  State<_PlexPinDialog> createState() => _PlexPinDialogState();
}

class _PlexPinDialogState extends State<_PlexPinDialog> {
  static const _length = 4;

  static final _keyDigits = {
    for (var d = 0; d <= 9; d++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d): '$d',
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + d): '$d',
    },
  };

  String _digits = '';
  String? _error;
  bool _busy = false;

  void _add(String digit) {
    if (_busy || _digits.length == _length) return;
    setState(() {
      _digits += digit;
      _error = null;
    });
    if (_digits.length == _length) _submit();
  }

  void _delete() {
    if (_busy || _digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final error = await widget.submit(_digits);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _error = error;
      _digits = '';
      _busy = false;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _delete();
      return KeyEventResult.handled;
    }
    final digit = _keyDigits[event.logicalKey];
    if (digit == null) return KeyEventResult.ignored;
    _add(digit);
    return KeyEventResult.handled;
  }

  Widget _key(String digit, {bool autofocus = false}) => Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 64,
          height: 52,
          child: OutlinedButton(
            key: Key('plex-pin-key-$digit'),
            autofocus: autofocus,
            onPressed: _busy ? null : () => _add(digit),
            child: Text(digit, style: const TextStyle(fontSize: 20)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('PIN for ${widget.userName}'),
      content: Focus(
        onKeyEvent: _onKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _length; i++)
                  Container(
                    key: Key('plex-pin-dot-$i'),
                    margin: const EdgeInsets.all(6),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _digits.length
                          ? theme.colorScheme.primary
                          : Colors.transparent,
                      border: Border.all(color: theme.colorScheme.outline),
                    ),
                  ),
              ],
            ),
            SizedBox(
              height: 24,
              child: _busy
                  ? const Center(
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : _error == null
                      ? null
                      : Text(
                          _error!,
                          key: const Key('plex-pin-error'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in row) _key(d, autofocus: d == '1'),
                ],
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 72),
                _key('0'),
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: SizedBox(
                    width: 64,
                    height: 52,
                    child: IconButton(
                      key: const Key('plex-pin-delete'),
                      tooltip: 'Delete',
                      onPressed: _busy ? null : _delete,
                      icon: const Icon(Icons.backspace_outlined),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('plex-pin-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
