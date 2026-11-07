/// The choice of what a folder added to a files library holds, shared by
/// Add folder and Add WebDAV.
library;

import 'package:flutter/material.dart';

import '../../../core/sources/files/media_names.dart';
import '../../../l10n/l10n.dart';

String filesLibraryKindLabel(AppLocalizations l10n, FilesLibraryKind kind) =>
    switch (kind) {
      FilesLibraryKind.movies => l10n.filesKindMovies,
      FilesLibraryKind.series => l10n.filesKindSeries,
      FilesLibraryKind.mixed => l10n.filesKindMixed,
    };

class FilesLibraryKindPicker extends StatelessWidget {
  const FilesLibraryKindPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final FilesLibraryKind value;
  final ValueChanged<FilesLibraryKind>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return DropdownButton<FilesLibraryKind>(
      value: value,
      isDense: true,
      onChanged: onChanged == null
          ? null
          : (kind) {
              if (kind != null) onChanged(kind);
            },
      items: [
        for (final kind in FilesLibraryKind.values)
          DropdownMenuItem(
            key: ValueKey('files-kind-${kind.name}'),
            value: kind,
            child: Text(filesLibraryKindLabel(context.l10n, kind)),
          ),
      ],
    );
  }
}
