# Stash scenes: next and previous scene in the player

## Goal

When a Stash scene is playing, the viewer can step to the previous or next
scene in the list they opened it from, and the player offers the next scene
with the Up Next countdown when one ends, as it does for episodes.

### Decisions taken

- **Order** is the list the scene was opened from: the Scenes library with
  its sort and filters (the home library preview row, sorted by recently
  added, is this origin too), search results, or the source's Continue
  Watching rail.
- **Auto-advance** reuses the episode Up Next prompt and countdown.
- **Scope** is Stash scenes only. The plumbing is source-neutral, but only a
  source implementing `SceneSequence` turns it on. Movies and other videos
  keep today's behaviour (no previous/next).
- **Transport** is approach A: the list travels in the route as a small
  descriptor, and the Stash source resolves neighbours by re-running the same
  query. Rejected: an in-memory snapshot of loaded IDs (lost on reload and
  deep link, bounded by loaded pages) and reusing `/player/queue`
  (Mydia-shaped, the URL grows with the list, frozen at play time).

### Today

The player has previous/next buttons, keyboard PageUp/PageDown, OS
media-session actions and the Up Next prompt, all driven by
`UpNextController`'s season episode list and gated on
`mediaType == 'episode'`. Stash scenes are `ItemKind.video` with no show or
season (`StashMediaSource.children` is empty), so none of it ever appears.

## Design

### 1. `PlaybackSequence` and how it travels

A new immutable domain type in `player/lib/domain/sources/`:

| field | meaning |
| --- | --- |
| `origin` | `library`, `search`, `continueWatching` |
| `sortId`, `descending`, `filterIds` | the library query (origin `library`) |
| `query` | the search text (origin `search`) |
| `position` | 0-based index of the scene in that list |

It encodes to and decodes from flat route query parameters with a `seq`
prefix, for example
`seq=library&seqSort=date&seqDesc=1&seqFilter=unplayed&seqPos=37`. Missing or
malformed parameters decode to null, which means no previous/next, exactly as
today.

`detail_links.dart` stays the only place that builds locations:
`sourceItemLocation(ref, sequence:)` and
`sourcePlayerLocation(ref, ..., sequence:)` take an optional sequence.

Entry points that attach one, only when the item's source implements
`SceneSequence`:

- the library grid (`source_library_screen.dart`): its current
  `BrowseQuery` and the tapped card's index;
- search results (`source_search_screen.dart`): the query and index;
- the Continue Watching rail for a Stash source: the origin and index;
- the home library preview row (recently-added sort): origin `library` with
  that sort, and the index. Home's Recently Added rows hold no Stash scenes,
  so there is no separate recently-added origin.

The scene detail screen's Play button (`source_item_screen.dart`) forwards
the sequence it was opened with. Merged All servers views and similar-item
rails attach none: they mix sources or have no stable order. A deep link with
no `seq` parameters plays with no previous/next.

**Random sort.** `stashSortOptions`' `random` becomes Stash's seeded
`random_<seed>` sort. The seed is held per `StashMediaSource` instance (one
random seed per instance, injectable for tests) rather than picked by the
library screen, so the grid's pages and the sequence's stepping see one stable
order for the whole app session. This also stops the grid's own pages
reshuffling between page loads, which happens today. A web reload builds a new
source and so reshuffles; a neighbour lookup then misses the scene at its
recorded position and falls back to the id scan.

### 2. Resolving neighbours in the Stash source

A new optional capability in `core/sources/capabilities.dart`:

```dart
abstract interface class SceneSequence {
  Future<SequenceNeighbours> neighbours(ItemRef ref, PlaybackSequence seq);
}
```

`SequenceNeighbours` carries `previous` and `next`, each a nullable
`SequenceNeighbour` (an `ItemSummary` plus its `position` in the list). Only `StashMediaSource` implements it.

The Stash implementation rebuilds the `findScenes` variables the origin used.
`browse`, `search`, `continueWatching` and `neighbours` all
take them from one private builder, so the sequence cannot drift from what
the screen showed. It fetches the page or pages covering
`position - 1 .. position + 1` at `per_page` 60, then:

1. If the scene is at `position`, return its neighbours.
2. If not (a scene was added, or a watched scene left Continue Watching),
   look for the scene's id in the fetched window, then scan up to 5 pages
   from the start.
3. If it is still not found, treat the scene now at `position` as next and
   the one before it as previous, so stepping continues instead of
   dead-ending.

Search is a single 40-item page today and stays bounded to it.

A transport failure or GraphQL error answers no neighbours: the buttons do
not appear and playback is unaffected.

`stashSummary` starts setting `defaultVersionId` from the scene's first file,
so a neighbour's file id is known without a second query. A neighbour with
no file counts as no neighbour: opening it would give a player with no file
id.

### 3. Player wiring

**Session.** `PlaybackSession` gains:

- `Future<SequenceNeighbours?> sequenceNeighbours()`. `SourcePlaybackSession`
  answers it from the route's `PlaybackSequence` when its source implements
  `SceneSequence`; every other session answers null.
- `String sequenceLocation(SequenceNeighbour n)`: the next player location,
  carrying the same sequence at `n`'s position.

**`UpNextController`.** A sequence mode beside season mode, set by
`setSequence(neighbours)` once the session answers (behind the screen's
existing load-generation check, like `setSeason`). `hasPrevious`, `hasNext`
and `target` read whichever mode is active. `playNext` and `playPrevious`
route through `sequenceLocation` on the same save-progress-then-replace path
episodes take. The controller handles a set sequence before it reads the
`isEpisode` gate, so that gate is unchanged. The transport buttons, keyboard keys, OS media-session next/previous
and TV remote need no change.

**Up Next prompt.** `UpNextTarget` gains a scene variant: the scene title,
the studio as subtitle, the screenshot as thumbnail, and no SxEy label
(`next_up_labels.dart`). The prompt triggers through the existing
`shouldOfferUpNext`; Stash reports no credits segment, so the no-credits
window applies. For a sequence that window is `sceneUpNextWindow`: 10% of
the file, at least the countdown (10s) and at most `upNextFallbackWindow`
(60s), so a short clip is not left mid-play by a countdown that started at
its beginning. Episodes keep the fixed 60s. Countdown, dismiss and the per-file
cancellation rule are reused unchanged.

## Testing

- `PlaybackSequence` route encoding round-trips every origin; malformed and
  partial parameters decode to null.
- `StashMediaSource.neighbours` against a scripted client: middle, first and
  last scene; the list shifted by one; the scene gone; a GraphQL error.
- Seeded random sort returns the same order across pages.
- `UpNextController` sequence mode: `hasPrevious`/`hasNext`, `playNext`,
  `playPrevious`, the countdown firing into the next scene.
- Widget test: a Stash scene opened from the library grid shows working
  previous/next; the same scene from a deep link shows neither.

## Docs

A paragraph in `player/lib/core/sources/README.md` beside "Source episodes
get Up Next", describing `SceneSequence` and the `seq` route parameters.

## Out of scope

- Previous/next for movies or other sources' videos.
- A visible queue or list overlay for scenes.
- Sequences across merged All servers views.
