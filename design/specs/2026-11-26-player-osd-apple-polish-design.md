# Player: Apple-style OSD polish

Date: 2026-11-26
Status: implemented

## Goal

The playback OSD has its layout
(`design/specs/2026-11-23-player-osd-redesign-design.md`), a polish pass
(#1525) and Liquid Glass (#1526). It still shows the title as one string in a
pill in the top corner, the bottom scrim ends in a visible band, and the
scrubber carries a permanent thumb. This pass takes the title treatment and the
finish of Apple's TV app player and keeps our layout: the control row stays
under the scrubber on every tier.

Background: `design/research/2026-11-26-apple-player-osd-layout.md`. What this
design takes from it:

- A two-line title block, left-aligned, directly above the scrubber: a small
  line over a large bold title.
- Bare text on the dimmed picture. Glass is for controls.
- A thumbless track at rest.

What it leaves: Apple's centre transport for pointer users. The remote tier
cannot use a centre cluster, so adopting it would split TV from desktop.

## Success criteria

- Same controls, same behaviour, on every input tier. Nothing is added to or
  removed from what each tier can do.
- TV press counts and focus order are identical to `master`. Every
  `*_tv_test.dart` passes unchanged under `MYDIA_FORCE_TV=true`.
- An episode shows its show name as the title with "S2, E4 · Episode name"
  above it. A movie shows its year above its title.
- The bar height does not change when the small line arrives or is absent.
- The title block meets the legibility contract over a pure-white frame in the
  `off`, `sampled` and `dry` glass modes: 4.5:1 for the small line, 3:1 for the
  large title.
- The bottom bar never overflows from 320 px up, with a title of any length.
- No visible edge in the scrim.

## Out of scope

- A centre transport for pointer or remote input.
- Chapter ticks, picture-in-picture, skip amounts.
- Show and hide motion for the OSD as a whole.
- Any new glass surface. Existing ones keep their `OsdGlass` recipes.
- Chapter or episode art in the title block.

## Layout

```
 (‹)                                                   [fit | cast]   top bar

 S2, E4 · Low Tide
 The Lantern Coast                                                    title block
 0:21:47 ━━━━━━━━━━━━━━━━━────────────────────────────── −0:31:18     scrubber
 [vol]             [⏮ −10 ▶ +10 ⏭]            [CC | audio | HD | ⛶]  control row
```

### Title block

A new `ChromeTitleBlock`, the first child of the bottom bar, left-aligned on the
bar's own left edge so the title, the elapsed timecode and the volume glyph
share one margin.

| Tier | Small line | Title |
| --- | --- | --- |
| Pointer, touch tablet | 13 / w500, white 78% | 22 / w700, tracking −0.01 em |
| Touch phone (`compactTouch`) | 11 / w500, white 78% | 15 / w700 |
| Remote | 18 / w500, white 78% | 30 / w700 |

- One line each, ellipsized. No shadow, no pill, no glass.
- The block's height is fixed per tier: the small line's box is reserved even
  when there is no small line, and the title sits at the bottom of the block.
  `ChromeBottomBar.heightFor` and `CompactChromeBottomBar.height` add that
  fixed height, so the caption lift and `ChromeMetrics.cornerInsetBottom` are
  known before any metadata loads.
- The block takes no focus and no pointer events.
- The title text keeps the key `ChromeTopBar.titleKey` (the constant stays
  where it is, so `playback_chrome_tv_test` finds it unchanged); the small
  line gets `ChromeTitleBlock.kickerKey`.
- Width: the block ellipsizes at the bar's content width. Skip Intro and Up
  Next sit above the bar (`cornerInsetBottom`), so they never share a row with
  it.

### What the two lines say

A new value type, `PlaybackTitle { title, kicker? }`, is resolved by the player
screen. `PlaybackChrome` keeps its `String? title` and gains `String? kicker`,
so existing callers and tests compile unchanged.

| Playing | `kicker` | `title` |
| --- | --- | --- |
| Episode, parts known | `S2, E4 · Episode name` (or `S2, E4` when the episode has no name) | Show name |
| Movie, year known | `2024` | Movie title |
| Anything else | none | The route's title string |

The route keeps passing one composed string (`sourcePlayerLocation`'s `title`
query), which shows at once as a single-line `PlaybackTitle`. `PlaybackDetail`
gains `showTitle`, `episodeNumber`, `episodeTitle` and `year`, filled by
`MydiaPlaybackSession.detail()` and `SourcePlaybackSession.detail()` where the
source knows them. When the detail lands, the player screen builds the
two-line `PlaybackTitle` from it. The detail-driven title is cleared with the
other per-file state at the start of every load. A source that cannot supply the parts stays
single-line. Any GraphQL field the Mydia session does not already select is
added to its document. `EpisodeDetail` already selects `episodeNumber`,
`title` and `show.title`, and `MovieDetail` selects `year`, so no document or
schema change is expected.

The `S2, E4` format is a localized message with two integer placeholders. The
window title, media session metadata and cast metadata keep using the route
string as they do today.

### Top bar

- The title leaves it. `ChromeTopBar.title` and the title pill are removed.
- Back becomes a disc: a circular `GlassSurface.osdPill` the height of the
  actions capsule, holding the chevron. `backKey` keeps its name;
  `titlePillKey` is removed.
- Capsule height goes from 36 to 40 px on pointer and tablet, with 20 px
  glyphs. The touch phone keeps 36. Corner overlays sit 4 px lower off the
  phone because the top bar is 40 px. The stats panel hangs exactly 12 px
  below the real top bar on every tier.
- The actions capsule (scaling, cast) and the phone's tracks capsule are
  unchanged otherwise. Placement still goes through `PlayerTopBarSlot`.
- Remote tier: `showBack` is false and scaling lives in the secondary cluster,
  so the top bar draws nothing there.

### Bottom bar

- Pointer and tablet: title block, timeline row, control row.
- Remote (`controlsFirst`): title block, control row, timeline row. The focus
  regions and their order are untouched.
- Touch phone: title block, then the single scrubber row. The bar grows from
  56 to 94 px (the 34 px block and its 4 px gap); captions lift with it.
- Gap between the title block and the next row: 6 px (4 px on the phone).

### Scrim

`ChromeScrim` stays one bottom band, with a new profile so no edge shows:

- Behind the timeline and control rows: `DepthTokens.osdTint` at
  `osdFillOpacity` (0.85), as today. Timecodes and bare glyphs keep the fill
  they are rated against.
- Across the title block: an eased descent to
  at least `DepthTokens.osdTitleScrimOpacity` at the block's top edge. The
  token is 0.66, set by the legibility sweep (small line 4.71:1, title 6.05:1
  over white); it started at 0.60.
- Above the block: the same descent continues to nothing.

It is one `Curves.easeInOut` from the plateau's top edge, so there is no joint
to show. Its length is the larger of two values: the title block height plus
`fadeExtentFor` (whose `maxFadeExtent` rises from 120 to 160 px, the 12% height
cap unchanged), and the length at which the curve is still at
`osdTitleScrimOpacity` when it reaches the block's top edge. The second value
wins on a landscape phone, where the scrim reaches about 160 px up a 350 px
screen; the upper half of that is under 30% opacity. `ChromeScrim` takes the
plateau height and the title block height as two arguments. There is still no
top band.

### Scrubber (`video_progress_bar.dart`)

| | Rest | Active (hover, drag, TV focus) |
| --- | --- | --- |
| Track height | 4 px | 6 px (8 today) |
| Thumb | none | 14 px white dot (18 px on TV focus, as today) |

- Played, buffered and unplayed colours are unchanged (played is
  `palette.primary`).
- The track is a capsule; the played portion's leading end is rounded and its
  trailing end is square while the thumb is hidden, so it reads as a fill
  rather than a second pill.
- Rest to active animates over 120 ms (`Curves.easeOut`): track height and
  thumb scale and opacity together. With Reduce Motion the change is instant.
- Hit areas, `ScrubBubble`, the scrub cursor and span, and `tv_scrubber.dart`
  behaviour are unchanged. `thumbKey` stays mounted at zero opacity at rest so
  key lookups keep working.
- The volume slider is not changed.

## Components

All under `player/lib/presentation/widgets/video_controls/` unless a path is
given.

| File | Change |
| --- | --- |
| `chrome_title_block.dart` | New. `ChromeTitleBlock` and its per-tier metrics. |
| `playback_title.dart` | New. `PlaybackTitle` and the builders from a route string and from a `PlaybackDetail`. |
| `chrome_bottom_bar.dart` | `ChromeBottomBar` and `CompactChromeBottomBar` take a `title` slot; `heightFor` and `height` include the block. |
| `chrome_top_bar.dart` | Title and title pill removed; back disc; 40 px capsules off the phone. |
| `chrome_scrim.dart` | Three-segment eased profile; takes the title block height. |
| `video_progress_bar.dart` | Rest and active states. |
| `playback_chrome.dart` | Gains `kicker`; builds the title block for the bar; passes both heights to the scrim. |
| `player/lib/core/theme/depth_tokens.dart` | `osdTitleScrimOpacity`. |
| `player/lib/presentation/screens/player/session/playback_session_types.dart` | `PlaybackDetail` gains `showTitle`, `episodeNumber`, `episodeTitle`, `year`. |
| `player/lib/presentation/screens/player/session/mydia_playback_session.dart`, `source_playback_session.dart` | Fill the new fields. |
| `player/lib/presentation/screens/player/player_screen.dart` | Builds `PlaybackTitle` from the route string, then from the detail. |
| `player/lib/l10n/` | The `S{season}, E{episode}` message. |
| `player/tool/liquid_glass_lab/` | The `osd` scene follows the new top and bottom bars. |
| `player/docs/liquid-glass.md` | The OSD section's description of the top bar and scrim. |

## Testing

- **Unchanged and must pass:** every `*_tv_test.dart` under
  `MYDIA_FORCE_TV=true`; `panel_controls_test`; `transport_cluster_test`.
- **Title block:** two lines for an episode, year line for a movie, one line
  otherwise; the block's height is equal with and without a small line at each
  tier; ellipsis at 320 px with a long title; no focus node inside it.
- **`PlaybackTitle`:** each row of the table above, an episode with no name,
  and a detail that knows nothing.
- **Bottom bar:** the existing overflow widths (320, 599, 600, 899, 900, 1280,
  1920) with a long title; `heightFor` equals the rendered height on every
  tier; Skip Intro and Up Next rects clear the taller bar; the subtitle lift
  reference is still the bar's box.
- **Top bar:** `chrome_top_bar_test` rewritten for the back disc and the
  absence of a title; the disc is inert with no `onBack`; the remote tier
  renders nothing.
- **Scrim:** alpha is non-increasing from the bottom edge up; it equals the
  OSD fill across the plateau and is at least `osdTitleScrimOpacity` at the
  block's top edge on every tier, including a 350 px tall phone.
- **Legibility:** `osd_legibility_test` and the OSD cases in
  `liquid_glass_legibility_test` rate the small line and the title at the
  lightest scrim alpha each overlaps, over the full grey sweep. A failure is
  fixed in `osdTitleScrimOpacity`, never in a threshold.
- **Scrubber:** no visible thumb at rest; thumb and 6 px track on hover, drag
  and focus; instant under Reduce Motion; the played portion is still
  `palette.primary`.
- **Visual:** the bottom-bar golden is regenerated; `./dev player glass-diff`
  with the `osd` scene side-by-side in the PR.
- **Manual:** Android TV emulator (`./dev player android tv-run`), counting
  presses against `master`; a phone in landscape with subtitles on; desktop
  windowed and fullscreen; iOS and the macOS HDR surface with Liquid Glass on.

## Delivery

One PR, with this spec, the research note and the implementation plan
(`design/plans/2026-11-26-player-osd-apple-polish.md`).

`origin/worktree-player-native-liquid-glass` is in flight on native macOS
glass. It concerns the material of the pills, not their layout; check it for
conflicts in `chrome_top_bar.dart` before opening the PR.
