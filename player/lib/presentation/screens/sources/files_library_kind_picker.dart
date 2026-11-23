/// The choice of what a folder added to a files library holds, shared by
/// Add folder and Add WebDAV.
library;

import 'package:material_ui/material_ui.dart';

import '../../../core/sources/files/media_names.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/controls/app_select.dart';

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
    return AppSelect<FilesLibraryKind>(
      value: value,
      enabled: onChanged != null,
      semanticLabel: context.l10n.filesKindLabel,
      onChanged: (kind) => onChanged?.call(kind),
      items: [
        for (final kind in FilesLibraryKind.values)
          AppSelectItem(
            key: ValueKey('files-kind-${kind.name}'),
            value: kind,
            label: filesLibraryKindLabel(context.l10n, kind),
          ),
      ],
    );
  }
}
