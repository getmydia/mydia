import 'package:flutter/material.dart';

import '../../../core/theme/palette.dart';
import '../../../domain/navigation/source_nav.dart';
import '../../../l10n/l10n.dart';
import '../glass/glass_sheet.dart';

/// Bottom sheet listing the source's libraries and saved filters, opened by
/// a long-press on the phone bar's Home item.
Future<void> showLibrarySheet(
  BuildContext context, {
  required List<SourceNavEntry> entries,
  required ValueChanged<String> onNavigate,
}) {
  return showGlassSheet<void>(
    context: context,
    backgroundColor: context.palette.surfaceVariant,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(sheetContext.l10n.navLibraries,
                style: Theme.of(sheetContext).textTheme.headlineSmall),
          ),
          // The heading stays put; the rows scroll when the source has
          // more than the sheet's height allows (many libraries, or a
          // short landscape phone).
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                for (final entry in entries)
                  ListTile(
                    key: ValueKey('library-sheet-${entry.id}'),
                    leading: Icon(entry.icon),
                    title: Text(context.l10n.navEntryLabel(entry)),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onNavigate(entry.route);
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
