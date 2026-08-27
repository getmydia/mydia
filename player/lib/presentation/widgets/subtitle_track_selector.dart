import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
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

/// An error whose message was written for a viewer and may be shown as-is.
///
/// The sheet never renders a raw exception object: a transport failure
/// stringifies to an `OperationException` dump, and a wiring bug to
/// whatever the framework named it. But some failures carry advice only the
/// server can give, and dropping it strands the viewer. The concrete case
/// is a candidate token expiring after fifteen minutes: the generic "try
/// again" invites re-tapping the same stale token forever, where the
/// server's own "search again" is the one instruction that works. A
/// callback throws this to opt a specific message in; everything else it
/// throws still lands on the generic copy.
class SubtitleActionException implements Exception {
  /// Shown to the viewer verbatim, so it must read as plain guidance.
  final String message;

  const SubtitleActionException(this.message);

  @override
  String toString() => 'SubtitleActionException: $message';
}

enum _SheetMode { tracks, searching, results, downloading }

/// Languages offered as chips, in the same order [SubtitleCandidate]
/// displays them.
final _chipLanguages = SubtitleCandidate.languageNames.keys.toList();

/// The line to show a viewer for [error]: its own message when it was
/// written for one, and [fallback] for everything else.
String _viewerMessage(Object error, String fallback) =>
    error is SubtitleActionException ? error.message : fallback;

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
  required ValueListenable<int?> subtitleDelayMs,
  required bool canSaveDelay,
  required Future<void> Function(int deltaMs) onNudgeSubtitleDelay,
  required Future<void> Function() onResetSubtitleDelay,
  required Future<void> Function() onSaveSubtitleDelay,
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
      subtitleDelayMs: subtitleDelayMs,
      canSaveDelay: canSaveDelay,
      onNudgeSubtitleDelay: onNudgeSubtitleDelay,
      onResetSubtitleDelay: onResetSubtitleDelay,
      onSaveSubtitleDelay: onSaveSubtitleDelay,
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

  /// The delay row's current total (stored + live nudge), or `null` to
  /// hide the row entirely -- no track selected, or the stored offsets
  /// never loaded. A `ValueListenable`, not a plain value, because this
  /// sheet is a separate route from `player_screen.dart`'s own build
  /// method: a `setState` there would never reach a widget rebuilt here.
  final ValueListenable<int?> subtitleDelayMs;

  /// Whether the row's Save button should be offered at all, computed by
  /// the caller from `canSaveSubtitleDelay(currentTrack?.id)`
  /// (`subtitle_track_builder.dart`) -- false for an mpv-native track,
  /// whose id the next session's mpv probe has no reason to reproduce. Not
  /// itself reactive: unlike [subtitleDelayMs], [currentTrack] cannot
  /// change while this sheet is open (picking a different track closes it),
  /// so a plain bool captured at construction is enough. The nudge and
  /// Reset stay available regardless -- the delay still applies for the
  /// current session; only persistence is unavailable.
  final bool canSaveDelay;

  final Future<void> Function(int deltaMs) onNudgeSubtitleDelay;
  final Future<void> Function() onResetSubtitleDelay;
  final Future<void> Function() onSaveSubtitleDelay;

  const SubtitleTrackSelectorSheet({
    super.key,
    required this.tracks,
    this.currentTrack,
    required this.onSearch,
    required this.onDownload,
    required this.subtitleDelayMs,
    required this.canSaveDelay,
    required this.onNudgeSubtitleDelay,
    required this.onResetSubtitleDelay,
    required this.onSaveSubtitleDelay,
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
      // An arbitrary exception's own text is never shown to a viewer -- a
      // transport failure stringifies to an `OperationException` dump.
      // Logged instead, the same split `player_screen.dart`'s own
      // subtitle-fetch failure uses. Only a [SubtitleActionException],
      // whose message was written for a viewer, is rendered as-is.
      debugPrint('[SubtitleTrackSelectorSheet] Search failed: $e');
      if (!mounted) return;
      setState(() {
        _outcome = const SubtitleSearchOutcome(results: [], providers: []);
        _error = _viewerMessage(e, 'Subtitle search failed. Try again.');
        _mode = _SheetMode.results;
      });
    }
  }

  void _toggleLanguage(String code) {
    // A search already in flight owns the languages it was called with;
    // changing them here would not affect that request.
    if (_mode == _SheetMode.searching) return;

    final isRemoving = _languages.contains(code);
    // At least one language has to stay selected -- an empty list would
    // silently re-run the search against nothing rather than refuse the tap.
    if (isRemoving && _languages.length == 1) return;

    final languages = isRemoving
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
    // A second tap -- another result, or the same one twice -- while the
    // first is still in flight must not issue a second download. `_mode` is
    // set synchronously below, before anything is awaited, so this is safe
    // even against two taps landing in the same frame.
    if (_mode == _SheetMode.downloading) return;

    setState(() {
      _mode = _SheetMode.downloading;
      _error = null;
    });
    try {
      final track = await widget.onDownload(candidate);
      if (!mounted) return;
      Navigator.of(context).pop(SubtitleTrackPicked(track));
    } catch (e) {
      debugPrint('[SubtitleTrackSelectorSheet] Download failed: $e');
      if (!mounted) return;
      setState(() {
        _mode = _SheetMode.results;
        _error = _viewerMessage(
            e,
            'Could not download that subtitle. '
            'Try again.');
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
          // Hidden entirely (delayMs null) with no track selected or the
          // stored offsets never loaded -- see `subtitleDelayMs`'s dartdoc.
          // Reactive because a keyboard nudge or the initial load can
          // change the value while this sheet is already open.
          ValueListenableBuilder<int?>(
            valueListenable: widget.subtitleDelayMs,
            builder: (context, delayMs, _) {
              if (delayMs == null) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: Colors.grey, height: 1),
                  _SubtitleDelayRow(
                    delayMs: delayMs,
                    canSave: widget.canSaveDelay,
                    onNudge: widget.onNudgeSubtitleDelay,
                    onReset: widget.onResetSubtitleDelay,
                    onSave: widget.onSaveSubtitleDelay,
                  ),
                ],
              );
            },
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextButton.icon(
            onPressed: () => setState(() => _mode = _SheetMode.tracks),
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to tracks'),
            style: TextButton.styleFrom(foregroundColor: Colors.grey),
          ),
        ),
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
    // The curated roster plus whatever is actually selected: a device
    // locale outside the roster (rarer languages the curated list omits)
    // must still get a chip, or it would be silently unremovable. Built as
    // a set so the extra language does not appear twice when it is already
    // in the roster.
    final codes = {..._chipLanguages, ..._languages};
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final code in codes)
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

/// The delay row: steppers, the current value, Reset and Save -- the same
/// actions the `z`/`shift+z` keyboard shortcut reaches on desktop, so touch
/// and TV have an equivalent way in.
class _SubtitleDelayRow extends StatelessWidget {
  final int delayMs;

  /// Whether to offer Save at all -- see `canSaveDelay`'s dartdoc on
  /// [SubtitleTrackSelectorSheet] for why an mpv-native track omits it
  /// while keeping the steppers and Reset.
  final bool canSave;
  final Future<void> Function(int deltaMs) onNudge;
  final Future<void> Function() onReset;
  final Future<void> Function() onSave;

  const _SubtitleDelayRow({
    required this.delayMs,
    required this.canSave,
    required this.onNudge,
    required this.onReset,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Subtitle delay',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
          Row(
            children: [
              IconButton(
                key: const ValueKey('subtitle-delay-decrement'),
                icon: const Icon(
                  Icons.remove_circle_outline,
                  color: Colors.white,
                ),
                tooltip: '-100 ms',
                onPressed: () => onNudge(-100),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${delayMs >= 0 ? '+' : ''}$delayMs ms',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('subtitle-delay-increment'),
                icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                tooltip: '+100 ms',
                onPressed: () => onNudge(100),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('subtitle-delay-reset'),
                onPressed: onReset,
                child: const Text('Reset'),
              ),
              if (canSave)
                TextButton(
                  key: const ValueKey('subtitle-delay-save'),
                  onPressed: onSave,
                  child: const Text('Save'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
