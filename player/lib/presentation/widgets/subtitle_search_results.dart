import 'package:flutter/material.dart';

import '../../domain/models/subtitle_candidate.dart';

/// The results list for an online subtitle search.
///
/// Renders provider quota alongside any failures, so a viewer who searched
/// and got nothing back can tell whether that is because nobody has this
/// release yet or because a provider's shared quota is exhausted.
class SubtitleSearchResults extends StatelessWidget {
  final List<SubtitleCandidate> results;
  final List<SubtitleProviderStatus> providers;
  final List<String> languages;
  final ValueChanged<SubtitleCandidate> onSelect;

  const SubtitleSearchResults({
    super.key,
    required this.results,
    required this.providers,
    required this.languages,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final failures = providers.where((p) => p.failed).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final provider in providers)
          if (provider.quotaLabel != null)
            Padding(
              key: ValueKey('quota-${provider.name}'),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              child: Text(
                '${provider.name}: ${provider.quotaLabel}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
        for (final provider in failures)
          Padding(
            key: ValueKey('failure-${provider.name}'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
            child: Text(
              '${provider.name}: ${provider.error}',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ),
        if (results.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'No subtitles found for ${languages.join(', ')}. '
              'Try adding another language.',
              style: const TextStyle(color: Colors.grey),
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final result = results[index];
                return _ResultTile(
                  key: ValueKey(result.token),
                  candidate: result,
                  onTap: () => onSelect(result),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  final SubtitleCandidate candidate;
  final VoidCallback onTap;

  const _ResultTile({super.key, required this.candidate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        candidate.releaseName ?? candidate.displayLanguage,
        style: const TextStyle(color: Colors.white),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(
            candidate.displayLanguage,
            style: const TextStyle(color: Colors.grey),
          ),
          if (candidate.hashMatch)
            const Text(
              'Exact match',
              style: TextStyle(color: Colors.greenAccent, fontSize: 12),
            ),
          if (candidate.rating != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.star, size: 12, color: Colors.grey),
                const SizedBox(width: 2),
                Text(
                  candidate.rating!.toStringAsFixed(1),
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          Text(
            candidate.providerName,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
      trailing: candidate.hearingImpaired
          ? const Icon(Icons.hearing, color: Colors.grey, size: 18)
          : null,
      onTap: onTap,
    );
  }
}
