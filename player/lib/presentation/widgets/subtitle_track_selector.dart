import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/player/subtitle_language_prefs.dart';
import '../../domain/models/subtitle_candidate.dart';
import '../../domain/models/subtitle_track.dart';
import 'subtitle_search_results.dart';

/// What the subtitle sheet resolved to when it closed.
///
/// Three outcomes, not the `SubtitleTrack?` this sheet used to return.
/// `showModalBottomSheet` resolves to `null` on a barrier tap or a back
/// gesture, which made a dismissal indistinguishable from choosing "Off" --
/// harmless while the sheet only ever returned instantly, but not once
/// picking a track can itself take a while: a viewer backing out of the
/// sheet while a pick is still resolving must leave that pick alone, not
/// silently turn subtitles off. `player_screen.dart` switches on which of
/// these three it got instead of guessing from a null.
sealed class SubtitleTrackSelection {
  const SubtitleTrackSelection();
}

/// The viewer picked a track, whether it was already on the file or was
/// just downloaded.
final class SubtitleTrackPicked extends SubtitleTrackSelection {
  final SubtitleTrack track;
  const SubtitleTrackPicked(this.track);
}

/// The viewer picked "Off".
final class SubtitleTrackOff extends SubtitleTrackSelection {
  const SubtitleTrackOff();
}

/// The sheet closed with no choice made: a barrier tap or a back gesture.
final class SubtitleTrackSelectionCancelled extends SubtitleTrackSelection {
  const SubtitleTrackSelectionCancelled();
}

/// What a subtitle search produced.
class SubtitleSearchOutcome {
  final List<SubtitleCandidate> results;
  final List<SubtitleProviderStatus> providers;

  /// Set when the search itself failed rather than returning nothing.
  final String? error;

  const SubtitleSearchOutcome({
    required this.results,
    required this.providers,
    this.error,
  });
}

enum _SheetMode { tracks, searching, results, downloading }

/// Languages offered as chips, in the same order [SubtitleCandidate]
/// displays them.
final _chipLanguages = SubtitleCandidate.languageNames.keys.toList();

/// Shows a bottom sheet for selecting a subtitle track, or for searching for
/// and downloading one that is not already on the file.
///
/// Never resolves to a bare `null`: see [SubtitleTrackSelection] for why a
/// dismissal is reported distinctly from choosing "Off".
Future<SubtitleTrackSelection> showSubtitleTrackSelector(
  BuildContext context,
  List<SubtitleTrack> tracks,
  SubtitleTrack? currentTrack, {
  required Future<SubtitleSearchOutcome> Function(List<String>) onSearch,
  required Future<SubtitleTrack> Function(SubtitleCandidate) onDownload,
}) async {
  final result = await showModalBottomSheet<SubtitleTrackSelection>(
    context: context,
    backgroundColor: Colors.grey[900],
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => SubtitleTrackSelectorSheet(
      tracks: tracks,
      currentTrack: currentTrack,
      onSearch: onSearch,
      onDownload: onDownload,
    ),
  );
  return result ?? const SubtitleTrackSelectionCancelled();
}

/// Bottom sheet widget for subtitle track selection and search.
class SubtitleTrackSelectorSheet extends StatefulWidget {
  final List<SubtitleTrack> tracks;
  final SubtitleTrack? currentTrack;
  final Future<SubtitleSearchOutcome> Function(List<String>) onSearch;
  final Future<SubtitleTrack> Function(SubtitleCandidate) onDownload;

  const SubtitleTrackSelectorSheet({
    super.key,
    required this.tracks,
    this.currentTrack,
    required this.onSearch,
    required this.onDownload,
  });

  @override
  State<SubtitleTrackSelectorSheet> createState() =>
      _SubtitleTrackSelectorSheetState();
}

class _SubtitleTrackSelectorSheetState
    extends State<SubtitleTrackSelectorSheet> {
  _SheetMode _mode = _SheetMode.tracks;
  List<String> _languages = SubtitleLanguagePrefs.defaults;
  SubtitleSearchOutcome? _outcome;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLanguages());
  }

  Future<void> _loadLanguages() async {
    final languages = await SubtitleLanguagePrefs.load();
    if (!mounted) return;
    setState(() => _languages = languages);
  }

  Future<void> _search() async {
    setState(() {
      _mode = _SheetMode.searching;
      _error = null;
    });
    try {
      final outcome = await widget.onSearch(_languages);
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _error = outcome.error;
        _mode = _SheetMode.results;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _outcome = const SubtitleSearchOutcome(results: [], providers: []);
        _error = 'Subtitle search failed: $e';
        _mode = _SheetMode.results;
      });
    }
  }

  void _toggleLanguage(String code) {
    // A search already in flight owns the languages it was called with;
    // changing them here would not affect that request.
    if (_mode == _SheetMode.searching) return;

    final languages = _languages.contains(code)
        ? _languages.where((l) => l != code).toList()
        : [..._languages, code];
    setState(() => _languages = languages);
    unawaited(SubtitleLanguagePrefs.save(languages));

    // Results already on screen reflect the old language list, and leaving
    // them up would silently mislabel them as matching the new one.
    if (_mode == _SheetMode.results) {
      unawaited(_search());
    }
  }

  Future<void> _download(SubtitleCandidate candidate) async {
    setState(() {
      _mode = _SheetMode.downloading;
      _error = null;
    });
    try {
      final track = await widget.onDownload(candidate);
      if (!mounted) return;
      Navigator.of(context).pop(SubtitleTrackPicked(track));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mode = _SheetMode.results;
        _error = 'Could not download that subtitle: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Subtitles',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 16),
          Flexible(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return switch (_mode) {
      _SheetMode.tracks => _buildTracks(context),
      _SheetMode.searching => _buildProgress('Searching for subtitles...'),
      _SheetMode.downloading => _buildProgress('Downloading subtitle...'),
      _SheetMode.results => _buildResults(context),
    };
  }

  Widget _buildTracks(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TrackTile(
            title: 'Off',
            isSelected: widget.currentTrack == null,
            onTap: () => Navigator.of(context).pop(const SubtitleTrackOff()),
          ),
          const Divider(color: Colors.grey, height: 1),
          if (widget.tracks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No subtitle tracks available',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ...widget.tracks.map(
              (track) => _TrackTile(
                title: track.displayName,
                subtitle: track.embedded ? 'Embedded' : 'External',
                isSelected: widget.currentTrack?.id == track.id,
                onTap: () =>
                    Navigator.of(context).pop(SubtitleTrackPicked(track)),
              ),
            ),
          const Divider(color: Colors.grey, height: 1),
          ListTile(
            leading: const Icon(Icons.search, color: Colors.grey),
            title: const Text(
              'Search online',
              style: TextStyle(color: Colors.white),
            ),
            onTap: _search,
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.red),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final outcome =
        _outcome ?? const SubtitleSearchOutcome(results: [], providers: []);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLanguageChips(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ),
        const SizedBox(height: 12),
        Flexible(
          child: SubtitleSearchResults(
            results: outcome.results,
            providers: outcome.providers,
            languages: _languages,
            onSelect: _download,
          ),
        ),
      ],
    );
  }

  Widget _buildLanguageChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final code in _chipLanguages)
            _LanguageChip(
              key: ValueKey('language-chip-$code'),
              code: code,
              isSelected: _languages.contains(code),
              onTap: () => _toggleLanguage(code),
            ),
        ],
      ),
    );
  }
}

class _LanguageChip extends StatelessWidget {
  final String code;
  final bool isSelected;
  final VoidCallback onTap;

  const _LanguageChip({
    super.key,
    required this.code,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = SubtitleCandidate.languageNames[code] ?? code.toUpperCase();
    return Material(
      color: isSelected ? Colors.red : Colors.grey[850],
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Individual track selection tile.
class _TrackTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _TrackTile({
    required this.title,
    this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: const TextStyle(color: Colors.grey),
            )
          : null,
      trailing: isSelected ? const Icon(Icons.check, color: Colors.red) : null,
      onTap: onTap,
    );
  }
}
