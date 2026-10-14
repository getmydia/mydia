import 'package:flutter/material.dart';

import '../../../domain/navigation/source_nav.dart';
import '../glass_surface.dart';

/// Bottom sheet listing the source's libraries and saved filters, opened by
/// a long-press on the phone bar's Home item.
Future<void> showLibrarySheet(
  BuildContext context, {
  required List<SourceNavEntry> entries,
  required ValueChanged<String> onNavigate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => GlassSurface.modal(
      // The glass fill is a DecoratedBox; a transparent Material gives the
      // tiles' ink somewhere to paint above it.
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text('Libraries',
                    style: Theme.of(sheetContext).textTheme.headlineSmall),
              ),
              for (final entry in entries)
                ListTile(
                  key: ValueKey('library-sheet-${entry.id}'),
                  leading: Icon(entry.icon),
                  title: Text(entry.label),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onNavigate(entry.route);
                  },
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );
}
