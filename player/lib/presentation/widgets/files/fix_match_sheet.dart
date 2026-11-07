import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/files/media_names.dart';
import '../../../core/sources/media_source.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../../l10n/l10n.dart';
import '../glass/glass_sheet.dart';
import '../../../core/sources/sources_providers.dart' show mediaSourceProvider;
import '../source_artwork.dart';

/// Whether Fix match applies to [ref] on [source]: the source can edit
/// matches and this item can be matched.
bool canFixMatch(MediaSource? source, ItemRef ref) {
  final editing = source?.as<MatchEditing>();
  return source != null &&
      editing != null &&
      source.capabilities.contains(SourceCapability.matchEditing) &&
      editing.canEditMatch(ref);
}

/// Opens the Fix match sheet for [ref]: search TMDB, pin a result, or
/// unmatch. [title] prefills the search. Completes with true when a match
/// was set.
Future<bool> showFixMatchSheet(
  BuildContext context,
  MediaSource source,
  ItemRef ref, {
  String title = '',
}) async {
  final editing = source.as<MatchEditing>();
  if (editing == null) return false;
  final changed = await showGlassSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FixMatchSheet(
      editing: editing,
      item: ref,
      initialTitle: title,
    ),
  );
  return changed ?? false;
}

class FixMatchSheet extends ConsumerStatefulWidget {
  const FixMatchSheet({
    super.key,
    required this.editing,
    required this.item,
    required this.initialTitle,
  });

  final MatchEditing editing;
  final ItemRef item;
  final String initialTitle;

  @override
  ConsumerState<FixMatchSheet> createState() => _FixMatchSheetState();
}

class _FixMatchSheetState extends ConsumerState<FixMatchSheet> {
  late final _title = TextEditingController(text: widget.initialTitle);
  final _year = TextEditingController();
  List<TmdbCandidate>? _results;
  Object? _error;
  bool _busy = false;

  /// Bumped by every search and pick: an answer for an older one is
  /// dropped, so it can neither show stale results nor end the busy state
  /// of the newer one.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialTitle.isNotEmpty) _search();
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _title.text.trim();
    if (query.isEmpty) return;
    final attempt = ++_attempt;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = await widget.editing.searchMatches(
        widget.item,
        query,
        year: int.tryParse(_year.text.trim()),
      );
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _results = found;
        _busy = false;
      });
    } catch (e) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  Future<void> _pick(TmdbCandidate? choice) async {
    _attempt++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The source invalidates its listings and items once the match lands.
      await widget.editing.setMatch(widget.item, choice);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final results = _results;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.filesFixMatch,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('fix-match-title'),
                  controller: _title,
                  decoration:
                      InputDecoration(labelText: l10n.filesFixMatchTitleLabel),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 88,
                child: TextField(
                  key: const Key('fix-match-year'),
                  controller: _year,
                  decoration:
                      InputDecoration(labelText: l10n.filesFixMatchYearLabel),
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                ),
              ),
              IconButton(
                key: const Key('fix-match-search'),
                icon: const Icon(Icons.search_rounded),
                onPressed: _busy ? null : _search,
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l10n.sourceError(_error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (results != null && results.isEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(child: Text(l10n.filesFixMatchNoResults)),
            ),
          if (results != null && results.isNotEmpty)
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: results.length,
                itemBuilder: (context, i) {
                  final r = results[i];
                  final poster = r.posterPath;
                  const fallback = ColoredBox(
                    color: Color(0x22808080),
                    child: Icon(Icons.movie_outlined),
                  );
                  return ListTile(
                    key: ValueKey('fix-match-result-${r.id}'),
                    enabled: !_busy,
                    leading: SizedBox(
                      width: 40,
                      height: 60,
                      child: poster == null || poster.isEmpty
                          ? fallback
                          : SourceArtworkImage(
                              sourceId: widget.item.sourceId,
                              art: ArtworkRef(poster),
                              fallback: fallback,
                            ),
                    ),
                    title: Text(r.title),
                    subtitle: r.year == null ? null : Text('${r.year}'),
                    onTap: () => _pick(r),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('fix-match-unmatch'),
              onPressed: _busy ? null : () => _pick(null),
              child: Text(l10n.filesFixMatchUnmatch),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Fix match action for a detail screen's button row: null when the
/// item's source cannot edit matches or the item cannot be matched.
///
/// A new match usually moves the item to another id (the new TMDB number,
/// or its files in Folders). The detail page showing the old one then has
/// nothing left to show, so it is closed rather than left on a not-found
/// error.
VoidCallback? fixMatchAction(
  BuildContext context,
  WidgetRef ref,
  ItemRef item,
  String title,
) {
  final source = ref.watch(mediaSourceProvider(item.sourceId));
  if (source == null || !canFixMatch(source, item)) return null;
  return () async {
    final changed =
        await showFixMatchSheet(context, source, item, title: title);
    if (!changed || !context.mounted) return;
    try {
      await source.item(item);
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.notFound && context.mounted) {
        await Navigator.of(context).maybePop();
      }
    } catch (e) {
      // Any other failure is the detail page's own to show on refetch.
      debugPrint('[FixMatch] Could not recheck ${item.externalId}: $e');
    }
  };
}
