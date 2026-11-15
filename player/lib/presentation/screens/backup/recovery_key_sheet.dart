/// The backup recovery key: shown with its QR code, copy and save, and, when
/// turning backup on, confirmed as saved before the vault is created.
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/backup/backup_sync_service.dart';
import '../../../core/backup/recovery_key.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../../widgets/toast/toaster.dart';

/// Window width below which the sheet rises from the bottom instead of
/// opening as a dialog.
const double _compactWidth = 600;

/// Opens [child] as a bottom sheet on compact widths, otherwise as a dialog.
Future<T?> _showAdaptive<T>(BuildContext context, Widget child) {
  if (MediaQuery.sizeOf(context).width < _compactWidth) {
    return showGlassSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (_) => child,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (_) => GlassDialog(content: SizedBox(width: 460, child: child)),
  );
}

/// Turns backup on: shows a new recovery key and creates the vault once the
/// viewer ticked that they saved it. True when backup is now on.
Future<bool> showEnableBackupSheet(
    BuildContext context, BackupSyncService service) async {
  final enabled = await _showAdaptive<bool>(
      context, RecoveryKeySheet.enable(service: service));
  return enabled ?? false;
}

/// Shows [keyText] with its QR code, copy and save. Nothing to confirm.
Future<void> showRecoveryKeySheet(BuildContext context, String keyText) =>
    _showAdaptive<void>(context, RecoveryKeySheet.show(keyText: keyText));

/// Shows [keyText], the recovery key that just replaced the old one, and
/// stays up until the viewer presses Done: a tap outside or Back does not
/// close it, since the old key no longer works. [onDone] runs when Done is
/// pressed, and only then.
Future<void> showReplacedRecoveryKeySheet(BuildContext context, String keyText,
        {required VoidCallback onDone}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: GlassDialog(
          content: SizedBox(
            width: 460,
            child: RecoveryKeySheet.show(
                keyText: keyText, replaced: true, onDone: onDone),
          ),
        ),
      ),
    );

class RecoveryKeySheet extends StatefulWidget {
  const RecoveryKeySheet.enable({super.key, required this.service})
      : keyText = null,
        replaced = false,
        onDone = null;

  const RecoveryKeySheet.show(
      {super.key, required this.keyText, this.replaced = false, this.onDone})
      : service = null;

  /// The key just replaced the old one: says so above the key.
  final bool replaced;

  /// Runs when the viewer presses Done, before the sheet closes.
  final VoidCallback? onDone;

  /// Set when turning backup on.
  final BackupSyncService? service;

  /// Set when showing a key this device already holds.
  final String? keyText;

  @override
  State<RecoveryKeySheet> createState() => _RecoveryKeySheetState();
}

class _RecoveryKeySheetState extends State<RecoveryKeySheet> {
  RecoveryKey? _key;
  late String? _display = widget.keyText;

  /// The viewer ticked that they saved the key on screen.
  bool _saved = false;
  bool _busy = false;

  /// Turning on failed and [_display] is the replacement key.
  bool _retrying = false;

  bool get _enabling => widget.service != null;

  bool get _canTurnOn => _saved && _key != null && !_busy;

  @override
  void initState() {
    super.initState();
    if (_enabling) _newKey();
  }

  /// Key texts this sheet put on the clipboard.
  final _copied = <String>{};

  @override
  void dispose() {
    if (_copied.isNotEmpty) unawaited(_clearClipboard(_copied));
    super.dispose();
  }

  /// Empties the clipboard if it still holds a key this sheet copied, so
  /// the key does not linger there for other apps.
  static Future<void> _clearClipboard(Set<String> copied) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (copied.contains(data?.text)) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (e) {
      debugPrint('[Backup] Clipboard not cleared: ${e.runtimeType}');
    }
  }

  Future<void> _newKey() async {
    final key = await widget.service!.prepareEnable();
    if (!mounted) return;
    setState(() {
      _key = key;
      _display = key.display;
      // A new key was not saved yet, whatever was ticked for the last one.
      _saved = false;
    });
  }

  Future<void> _turnOn() async {
    final key = _key;
    if (key == null) return;
    setState(() => _busy = true);
    try {
      await widget.service!.confirmEnable(key);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('[Backup] Turning on failed: ${e.runtimeType}');
      if (!mounted) return;
      if (widget.service!.status.value is BackupUnavailable) {
        showToast(context, context.l10n.backupUnavailable,
            kind: ToastKind.error);
        Navigator.of(context).pop(false);
        return;
      }
      // The relay may have created the vault with this key before failing:
      // its lookup handle is taken, so the next try needs a new key.
      setState(() => _retrying = true);
      await _newKey();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    final toaster = Toaster.of(context);
    final copied = context.l10n.backupKeyCopied;
    final text = _display ?? '';
    _copied.add(text);
    await Clipboard.setData(ClipboardData(text: text));
    toaster.show(copied, kind: ToastKind.success);
  }

  Future<void> _save() async {
    final name = context.l10n.backupKeyFileName;
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return;
    await XFile.fromData(
      utf8.encode('${_display ?? ''}\n'),
      mimeType: 'text/plain',
      name: name,
    ).saveTo(location.path);
  }

  /// Desktop installs can save a file to print or store; phones copy.
  static bool get _canSave =>
      !kIsWeb &&
      const {
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final display = _display;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.backupKeySheetTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(l10n.backupKeySheetBody,
                style: TextStyle(color: palette.textSecondary)),
            if (widget.replaced) ...[
              const SizedBox(height: 12),
              Text(
                l10n.backupKeyReplacedNotice,
                key: const Key('recovery-key-replaced'),
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_retrying) ...[
              const SizedBox(height: 12),
              Text(
                l10n.backupEnableFailedNewKey,
                key: const Key('recovery-key-retry'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            if (display == null)
              const Center(child: CircularProgressIndicator())
            else ...[
              SelectableText(
                display,
                key: const Key('recovery-key-text'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  height: 1.6,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: QrImageView(
                  key: const Key('recovery-key-qr'),
                  data: display.replaceAll(' ', ''),
                  size: 160,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    key: const Key('recovery-key-copy'),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: Text(l10n.commonCopy),
                    onPressed: _copy,
                  ),
                  if (_canSave)
                    TextButton.icon(
                      key: const Key('recovery-key-save'),
                      icon: const Icon(Icons.save_alt_rounded, size: 18),
                      label: Text(l10n.backupKeySave),
                      onPressed: _save,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (_enabling && display != null) ...[
              CheckboxListTile(
                key: const Key('recovery-key-saved-checkbox'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _saved,
                onChanged:
                    _busy ? null : (v) => setState(() => _saved = v ?? false),
                title: Text(l10n.backupKeySavedCheckbox),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(false),
                    child: Text(l10n.commonCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('recovery-key-confirm-button'),
                    onPressed: _canTurnOn ? _turnOn : null,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.backupKeyConfirmButton),
                  ),
                ],
              ),
            ] else if (!_enabling)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('recovery-key-done'),
                  onPressed: () {
                    widget.onDone?.call();
                    Navigator.of(context).pop();
                  },
                  child: Text(l10n.commonDone),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
