/// Add a folder on this computer as a files library. Desktop only in this
/// phase: the folders are plain paths.
library;

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/files/files_accounts.dart';
import '../../../core/sources/files/media_names.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import 'files_library_kind_picker.dart';

/// Whether this platform can add a folder on this device: Linux, Windows
/// and macOS, where folders are plain paths.
bool get localFoldersSupported =>
    !kIsWeb &&
    const {TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS}
        .contains(defaultTargetPlatform);

/// Opens the system folder picker; null when the viewer cancels. Tests
/// override it.
final directoryPickerProvider = Provider<Future<String?> Function()>(
    (_) => () => file_selector.getDirectoryPath());

class AddFolderScreen extends ConsumerStatefulWidget {
  const AddFolderScreen({super.key});

  @override
  ConsumerState<AddFolderScreen> createState() => _AddFolderScreenState();
}

class _AddFolderScreenState extends ConsumerState<AddFolderScreen> {
  String? _path;
  FilesLibraryKind _kind = FilesLibraryKind.mixed;
  bool _busy = false;
  bool _failed = false;

  Future<void> _choose() async {
    final path = await ref.read(directoryPickerProvider)();
    if (!mounted || path == null) return;
    setState(() {
      _path = path;
      _failed = false;
    });
  }

  Future<void> _add() async {
    final path = _path;
    if (path == null) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final id = await ref.read(filesAccountsProvider).addLocalRoot(
            path: path,
            kind: _kind,
            accountName: context.l10n.filesThisDevice,
          );
      ref.read(selectedSourceIdProvider.notifier).select(id);
      if (!mounted) return;
      context.go(sourceHomeLocation(id));
    } catch (e) {
      debugPrint('[AddFolder] Could not add $path: $e');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.filesAddFolderTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              OutlinedButton.icon(
                key: const Key('add-folder-choose'),
                autofocus: true,
                onPressed: _busy ? null : _choose,
                icon: const Icon(Icons.folder_open_rounded),
                label: Text(context.l10n.filesChooseFolder),
              ),
              const SizedBox(height: 12),
              Text(
                path ?? context.l10n.filesNoFolderChosen,
                key: const Key('add-folder-path'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text(context.l10n.filesKindLabel,
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              FilesLibraryKindPicker(
                key: const Key('add-folder-kind'),
                value: _kind,
                onChanged:
                    _busy ? null : (kind) => setState(() => _kind = kind),
              ),
              if (_failed) ...[
                const SizedBox(height: 16),
                Text(context.l10n.filesAddFolderFailed,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('add-folder-save'),
                onPressed: _busy || path == null ? null : _add,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(context.l10n.filesAddFolderButton),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
