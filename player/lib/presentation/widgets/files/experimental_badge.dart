library;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

/// Files libraries (local folders and WebDAV shares) are very experimental.
/// These widgets say so wherever one is added, so a viewer knows to expect
/// rough edges before trusting a library to it.

/// A small "Experimental" pill, for the trailing slot of a tile.
class ExperimentalBadge extends StatelessWidget {
  const ExperimentalBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        context.l10n.filesExperimentalBadge,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onTertiaryContainer),
      ),
    );
  }
}

/// The notice at the top of the Add folder and Add WebDAV screens.
class FilesExperimentalNotice extends StatelessWidget {
  const FilesExperimentalNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.filesExperimentalNotice,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
