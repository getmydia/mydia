library;

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

/// Files libraries (local folders, WebDAV, SMB and S3) are very experimental.
/// The Add server screen marks their section, and this notice says so again at
/// the top of each form, so a viewer knows to expect rough edges before
/// trusting a library to one.

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
