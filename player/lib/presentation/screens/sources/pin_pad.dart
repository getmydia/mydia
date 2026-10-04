/// Digit entry that works with touch, a mouse and a TV remote's D-pad.
library;

import 'package:flutter/material.dart';

import '../../../core/sources/lock/pin_store.dart';

class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onSubmit, this.autofocus = true});

  /// Returns an error to show under the dots, or null on success.
  final Future<String?> Function(String pin) onSubmit;
  final bool autofocus;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  void _digit(String d) {
    if (_busy || _pin.length >= 6) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!PinStore.isValidPin(_pin)) {
      setState(() => _error = 'Enter 4 to 6 digits.');
      return;
    }
    setState(() => _busy = true);
    final error = await widget.onSubmit(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _pin = '';
    });
  }

  Widget _key(String id, Widget child, VoidCallback onPressed,
          {bool autofocus = false}) =>
      Padding(
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          width: 72,
          height: 56,
          child: FilledButton.tonal(
            key: Key('pin-pad-$id'),
            autofocus: autofocus,
            onPressed: onPressed,
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget digit(String d, {bool autofocus = false}) =>
        _key(d, Text(d, style: theme.textTheme.titleLarge), () => _digit(d),
            autofocus: autofocus);
    return Column(
      key: const Key('pin-pad'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          List.filled(_pin.length, '•').join(' ').padRight(1),
          key: const Key('pin-pad-dots'),
          style: theme.textTheme.headlineMedium,
        ),
        SizedBox(
          height: 24,
          child: _error == null
              ? null
              : Text(_error!,
                  key: const Key('pin-pad-error'),
                  style: TextStyle(color: theme.colorScheme.error)),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final d in row)
                digit(d, autofocus: widget.autofocus && d == '1'),
            ],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _key('back', const Icon(Icons.backspace_outlined), _backspace),
            digit('0'),
            _key('ok', const Icon(Icons.check_rounded), _submit),
          ],
        ),
      ],
    );
  }
}

/// Asks for a new PIN twice. Null when cancelled.
Future<String?> showPinSetupDialog(BuildContext context) => showDialog<String>(
      context: context,
      builder: (context) => const _PinSetupDialog(),
    );

class _PinSetupDialog extends StatefulWidget {
  const _PinSetupDialog();

  @override
  State<_PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<_PinSetupDialog> {
  String? _first;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('pin-setup-dialog'),
      title: Text(_first == null ? 'Choose a PIN' : 'Enter it again'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('It unlocks locked and hidden servers when Face ID or '
              'your device passcode cannot. There is no way to recover it.'),
          const SizedBox(height: 16),
          // The pad clears itself after each submit; a stable key keeps the
          // mismatch message visible.
          PinPad(
            onSubmit: (pin) async {
              if (_first == null) {
                setState(() => _first = pin);
                return null;
              }
              if (pin != _first) {
                setState(() => _first = null);
                return 'The PINs did not match. Start again.';
              }
              Navigator.of(context).pop(pin);
              return null;
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('pin-setup-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
