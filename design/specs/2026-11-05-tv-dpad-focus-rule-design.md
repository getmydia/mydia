# One D-pad focus rule for the TV player

## Why

Navigating the Android TV build (tested on a Chromecast with Google TV) with
the remote is still hard. The complaint is not one broken screen: on every
screen, a D-pad press regularly lands focus somewhere the viewer did not
expect.

The cause is structural. Inside the content area, every directional press is
answered by Flutter's built-in geometric search
(`DirectionalFocusTraversalPolicyMixin`): "the nearest focusable thing in that
direction". The only custom rule is `RegionTraversalPolicy`
(`player/lib/core/focus/region_traversal_policy.dart`), which governs the edge
between the navigation rail and the content. The geometric search has no
memory, so:

- DOWN from a card lands on whichever card in the next row happens to be
  geometrically closest, which depends on how that row is currently scrolled,
  and can be a card that is built but off-screen (rails keep a 2400px cache
  extent on TV precisely so traversal can reach items).
- UP does not return to the card you came from.

Past fixes (rail edge handoff, dialog focus targets, the OSD scrubber,
`FocusRevealSection`, `RailFocusScroller`) each patched one symptom. Recent
shell work (floating rail, iPad and macOS sidebars, art under the rail) was
built mostly against touch and desktop. Only nine test files send arrow keys,
so wrong landings are not caught.

## Goal

Replace "nearest on screen" with one predictable rule, applied in one shared
place, and pin it with D-pad tests on every main screen so a regression fails
CI.

## The rule (decided by the user)

Google TV behavior: **a row remembers its place.**

- Each horizontal row (rail) remembers the item that last had focus in it.
- Entering a row vertically (UP or DOWN from another row or section) lands on
  that remembered item. A row never visited lands on its first item.
- Therefore DOWN then UP always returns to the exact item you left,
  regardless of either row's scroll position.
- LEFT and RIGHT inside a row move one item at a time, as today.
- A row remembers **the item, not the slot** (decided by the user). If
  Continue Watching moves the title you had focused to the front, coming back
  into the row lands on that title at its new position. Memory is keyed by a
  stable item identity, so every row supplies one.
- If the remembered item no longer exists (list reloaded, item removed),
  fall back to the nearest surviving index, else the first item.

Other shapes:

- **Poster grids** (`BrowseGrid` and other grid screens such as the library
  and collection detail): inside the grid, UP and DOWN move straight within the
  column (confirmed by the user). Entering the grid from outside (DOWN from a
  filter bar or a rail above it) lands on the grid's last-focused item, keyed
  by item like rows, else its first item (decided by the user). So UP out of
  the grid and DOWN again round-trips, the same as rows. A grid is therefore
  one more "remembering region" of the shared mechanism, with column-straight
  internal movement.
- **Button bars** (detail hero buttons, OSD control bar, row headers with
  buttons, season selector): treated as rows. They remember their place.
  (Builder's call, recorded here.)
- **One-column vertical lists** (settings, calendar, downloads list): entering
  from above or below lands on the list's remembered item, else the first
  visible item. Inside the list UP/DOWN step one item. Geometric search is not
  used to pick an entry point anywhere. (Builder's call.)
- **Detail pages** (movie, show, episode): vertical order is top to bottom by
  section: hero buttons, then seasons, then episodes, then cast and "similar"
  rails. Each rail section inside follows the row rule. (Confirmed.)
- **Navigation rail edge**: today's `RegionTraversalPolicy` behavior stays
  (LEFT from the first item of a row goes to the rail, row-confined left/right,
  popups never hand off behind themselves). RIGHT from the rail lands on the
  content's last-focused item. If it does not today, fixing it is in scope,
  done narrowly at the `onExit`/entry seam in `app_shell.dart` and pinned by a
  test, without restructuring `RegionTraversalPolicy`. (Builder's call.)
- **Player OSD**: its rows are the control bar (a button-bar row), the
  scrubber, and any track/queue strips (rows). UP/DOWN between them follows
  the rule: leaving the scrubber UP and coming back DOWN returns to the
  scrubber, and returning to the control bar lands on the last-focused
  control. The scrubber's own LEFT/RIGHT scrub semantics and Back-to-cancel
  are untouched. (Builder's call.)
- **Dialogs, sheets, menus**: unchanged contract: focus stays inside the popup.

## Scope

- **TV only** (decided by the user). Gated on
  `InputCapabilities.directionalPrimary` (`MYDIA_FORCE_TV` for testing).
  Phones, tablets, desktop, iPad with keyboard and the web keep today's
  behavior exactly, including Tab order.
- Screens in scope: everything reachable on TV: home, library/source
  listings and grids, search, movie/show/episode detail, season and episode
  rails, collections, continue watching / recently added / unwatched /
  favorites, downloads, calendar, settings, sources/all-servers, and the
  player OSD.

## Done means (decided by the user)

1. The rule lives in one shared place every screen uses, not per-screen
   key handlers. A new screen built from the shared rail/grid widgets gets
   the rule for free.
2. Automated D-pad widget tests (TV tier forced) for each main screen,
   asserting where focus lands after key sequences, including at minimum:
   - DOWN then UP returns to the starting item, with the destination row
     scrolled to a different offset than the source row.
   - Entering a never-visited row lands on its first item.
   - Entering a previously visited row lands on its remembered item.
   - LEFT from a row's first item reaches the navigation rail; RIGHT returns.
   - Grid UP/DOWN stays in the column; leaving a grid and re-entering
     lands on its remembered item.
   - A reordered row (remembered title moved to the front) re-enters on the
     same title.
   Screens with rows or grids (home, library/listings, search, detail,
   show/seasons, collections, the browse lists, all-servers) get the full
   set. Screens without them (settings, calendar, downloads, OSD) get a
   lighter set: first entry, round-trip in and out of their lists or bars, and
   LEFT to the rail and RIGHT back. (Builder's call.)
   These run in normal CI (`flutter test`).

A walkthrough on the real Chromecast is welcome but secondary; tests are the
bar.

## Non-goals

- No visual redesign of focus rings, cards or layouts.
- No change to non-TV input behavior.
- No change to the player OSD scrubber's D-pad semantics beyond making its
  entry/exit obey the rule.

## Anti-goals

- Focus moving somewhere the viewer cannot see (behind a popup, off-screen
  with no scroll to reveal it).
- A dead press where a sensible destination exists.
- Per-screen hand-wired arrow-key handlers that each re-implement the rule;
  that is the patch pattern this replaces.

## What exists to build on

- `RegionTraversalPolicy` and the rail/content `FocusScope` pairing in
  `app_shell.dart` (rail edge handoff, popup guard).
- `HorizontalRail` (`player/lib/presentation/widgets/horizontal_rail.dart`),
  the shared rail shell used by episode rails, downloaded-episode rails and
  source poster rows. Other rails (`cast_rail.dart`, `detail_similar_rail.dart`,
  `show_season_section.dart`, home rows) may build their own lists; the builder
  inventories them and routes every TV row through the shared mechanism.
- `RailFocusScroller` (centres the focused card on TV) and
  `FocusRevealSection` (reveals a whole section on entry). Keep their
  scrolling behavior.
- Existing focus tests in `player/test/core/focus/` and
  `tv_sidebar_traversal_tv_test.dart` as patterns for forcing the TV tier.
- Note: `ContentRail` is mentioned in comments but no longer exists.

## Left to the builder

- The mechanism: e.g. a row-level `FocusTraversalGroup`/`FocusScope` that
  records its last focused child and redirects vertical entry, versus extending
  the content region's policy to treat rows as units. Pick whatever keeps the
  rule in one place and coexists with `RegionTraversalPolicy`.
- How "row" is identified for screens that are not built from a shared rail
  widget, and whether those screens migrate to the shared widget.
- Whether a row's memory survives navigating away and back to the screen
  (default: survives while the screen's state is alive, e.g. back from a
  detail page to home keeps it; a cold reload does not).
- Test file layout and shared test helpers.
