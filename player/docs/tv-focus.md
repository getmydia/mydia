# TV D-pad focus: a row remembers its place

On the television tier (`InputCapabilities.directionalPrimary`), every D-pad
landing inside the content area and the player OSD obeys one rule. The design
is in `design/specs/2026-11-05-tv-dpad-focus-rule-design.md`; the code is
`lib/core/focus/focus_memory.dart`.

## The rule

1. Each row, grid, list and button bar remembers the item that last had focus
   in it, by a stable item id rather than by position.
2. Any move entering one from outside the region lands on that remembered
   item, whatever the direction: UP or DOWN from another row, RIGHT from a
   button beside a rail, RIGHT from the sidebar into a rail. One never visited
   lands on its first item, meaning the lowest built index (first visible
   item, for vertical lists). RIGHT from the sidebar goes through
   `SidebarFocusBoundary`, which returns to the card that left for the
   sidebar, and that card is the row's remembered item.
3. If the remembered item is gone or not built, focus lands on the item nearest
   its last index.
4. Moves inside a row (LEFT and RIGHT along a rail, column-straight in a grid)
   stay Flutter's geometric search, one item at a time.
5. Moves inside a popup (sheet, menu, dialog) are never redirected, and an
   emptied row is skipped.

Off the television tier none of this exists: the widgets return their child
untouched and the callback only delegates to Flutter's default.

## Opting a widget in

`HorizontalRail` and `BrowseGrid` already do it: each wraps its list in a
region and every built item in an item. Without `itemId` an item's index
stands in for its id, which remembers a place only while the order holds, so
pass a stable id:

```dart
HorizontalRail(itemCount: items.length, itemId: (i) => items[i].ref, ...)
BrowseGrid(itemCount: items.length, itemId: (i) => items[i].ref, ...)
```

Use the item's identity (`ItemSummary.ref`, a button's action name), never the
index, or a reordered row (Continue Watching moving a title to the front)
returns to the slot instead of the title.

A row that builds its own list wraps the list in a `FocusMemoryRegion` and
each item in a `FocusMemoryItem`:

```dart
FocusMemoryRegion(
  child: ListView.builder(
    scrollDirection: Axis.horizontal,
    itemCount: items.length,
    itemBuilder: (context, i) => FocusMemoryItem(
      id: items[i].ref,
      index: i,
      child: PosterCard(item: items[i]),
    ),
  ),
)
```

The item's focus target is the outermost traversable node inside it, so a card
with its own `Focus` or `InkWell` needs nothing else, and a control nested in
the card (an episode card's watched menu) is never picked over the card. For a
one-column vertical list pass `entry: FocusMemoryEntry.firstVisible`, so a
first visit lands on the top on-screen row rather than a cached row above the
viewport. On screen means the row's centre is inside the view, less the
`MediaQuery` padding, and inside every enclosing scroll viewport. The padding
matters for a list that scrolls under a translucent app bar
(`extendBodyBehindAppBar`), whose rows behind the bar are laid out inside the
viewport but cannot be read.

A region's memory lives in its state, so a region that is itself a child of a
lazy vertical list (a rail on Home, a hero's button bar) forgets everything
when the list drops it from its build cache, and on a television's logical
height (960x540 on a Chromecast) that is only a few rows away. On the
television tier `HorizontalRail` keeps itself alive
(`AutomaticKeepAliveClientMixin`, which also keeps its scroll offset), and
Home keeps its hero alive the same way. A new row-shaped region placed
directly in a lazy vertical list needs the same; one that wraps the whole list
(Settings, the calendar) or sits in a `SliverToBoxAdapter` (detail pages) does
not.

A list whose sections are built by separate widgets (Settings) cannot number
its rows from one builder. `SettingsFocusOrder` gives each section its place,
and the section turns its rows into items indexed by section then row. A list
the viewer can jump around in (the calendar's Today button and month sheet)
keys its region by a jump counter, so a jump starts it with nothing
remembered rather than returning to an entry far from the day asked for.

## Pages of sections: `FocusMemoryColumn`

Regions decide where a move lands *inside* the region it enters. Which region
UP or DOWN enters is still the geometric search's choice, and on a page whose
sections are not aligned that skips some. On a detail page Play sits at the
right of the hero and the button bar below it at the left, so DOWN from Play
overlaps a rail further down and the bar is never reached.

`FocusMemoryColumn` puts the page's top-to-bottom section order in one place.
With focus inside one of its regions, UP and DOWN focus the previous or next
region's entry target (`FocusMemoryRegionState.entryTarget()`, the same
answer the redirect uses), skipping regions with nothing focusable. The press
is left to normal traversal when there is no such region, when focus is
outside every region (a back button above the first section), or when focus is
inside a popup route. LEFT and RIGHT are never touched.

The order is the regions' order in the element tree under the column, read at
each press, because sections register as their data arrives and a lower one
can register first. A nested column orders its own regions.

`DetailScreenFrame` wraps every detail page in one. Every focus stop meant to
be reachable by UP and DOWN on such a page must therefore sit in a region, even
a lone one: Play (`HeroPlayControl`), the similar row's disclosure, and the
"Episodes" heading's buttons are one-item or small regions for that reason. A
focusable node outside every region is skipped by section moves; it stays
reachable from the sides. Do not put a vertical list region in a column, as
UP and DOWN would leave it at once.

## Where the callback is installed

Regions and items only record. The redirect happens in
`FocusMemory.requestFocus`, installed as a traversal policy's
`requestFocusCallback`, which every directional move Flutter makes goes
through. It is installed in two places only:

- the shell's region policy, built by `_region` in
  `lib/presentation/widgets/app_shell.dart`
  (`RegionTraversalPolicy(onExit: ..., requestFocusCallback: FocusMemory.requestFocus)`).
  `_region` builds both the content and the sidebar region, so both carry it;
  only the content region holds rows, so in the sidebar it only delegates;
- the player OSD's traversal group, which `PlaybackChrome` puts around the
  whole chrome on the television tier, because the OSD renders over the
  player route, outside the shell. The control bar (transport and the track
  and picture buttons beside it) is one region, since it is one row on screen
  and UP from the scrubber has to be able to return to either end of it. The
  scrubber is a one-item region nested inside it; without its own region it
  would belong to the bar's, and UP from it would never be redirected. The
  bar passes `initialId: TransportSurface.playPauseKey`: a scrub from the
  hidden OSD focuses the scrubber without passing through the bar, so UP can
  enter it with nothing remembered, and its lowest index is Previous episode
  or -10s. `initialId` is consulted after the remembered item and before the
  index and `entry` fallbacks, and only while that item is built.

A region outside both never redirects anything. Do not add per-screen arrow-key
handlers to get the same effect; that is the pattern this replaced. Section
order across a page is `FocusMemoryColumn`'s job, above.

## Testing

TV tests are files named `*_tv_test.dart`. Their `group` skips itself unless
the process is compiled with the TV define, because `InputCapabilities.forcedTv`
is a compile-time constant:

```bash
./dev flutter test --dart-define=MYDIA_FORCE_TV=true test/core/focus/focus_memory_tv_test.dart
```

CI runs every `test/**/*_tv_test.dart` file with that define in the
"Run television-tier tests" step. Screen-level tests mount through
`test/test_utils/tv_shell_harness.dart`, which lays out at a Chromecast's
960x540 logical pixels (1920x1080 at device pixel ratio 2), so lazy lists drop
rows where a real television does. Patterns to copy:
`test/core/focus/focus_memory_tv_test.dart` (rows, reorder, removal, popups)
and `test/presentation/widgets/tv_sidebar_traversal_tv_test.dart` (the sidebar
edge). Label each focusable with its item id via `Focus(debugLabel: ...)` and
assert on `FocusManager.instance.primaryFocus?.debugLabel` after
`tester.sendKeyEvent(...)` and `pumpAndSettle()`. Use invented titles only.
