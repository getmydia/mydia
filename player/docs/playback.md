# Playback: who decides what plays

The server answers "what can this device play" through `streamingCandidates`.
Everything after that is the player's, in `lib/core/playback/`:

| Unit | Job |
| --- | --- |
| `planPlayback` (`playback_planner.dart`) | candidates plus memory in, `PlaybackPlan` out. A top-level function, not a class. Pure. |
| `fallbackPlan` (`playback_planner.dart`) | the transcode a fallback lands on: quality choice, source height and a throughput reading in, an `HlsPlan` out (adaptive under Auto, source resolution under Original). Also a function. Pure. |
| `PlaybackMemory` | per server: file shapes that failed to decode here (14 days), and the latest bandwidth stall on each link path (1 hour). An abstract class; `HivePlaybackMemory` backs the app, `InMemoryPlaybackMemory` backs tests. |
| `PlaybackMonitor` | one `HealthSample` a second from media_kit's streams and the engine's frame counters (mpv's properties on native, the video element's on web) |
| `AdaptationPolicy` | the sample window in, `FallbackToTranscode` out. Pure state machine. |
| `PlaybackController` | starts and ends sessions, and replaces a source on the live `Player` |

`PlayerScreen` builds the inputs, calls the controller, and renders what it
reports. It does not read the candidate list itself.

## The decision, and where to look when it is wrong

The initial decision, made once when a file starts, logs one line:
`[PlayerScreen] Plan: <plan> shape=<codec>/<bucket> bitrateKbps=<n>
path=<path> stallCeilingKbps=<n>`, where `<plan>` is `directPlay (<reason>)`
for a direct play, or `<strategy> <rung> (<reason>)` for an HLS plan (copy or
transcode carry a rung; direct play does not). The reason names the rule that
fired. `<path>` is the link path (`direct`, `relay`, `mixed`, `http`, or
`unknown` while a p2p connection has no peer path), and `stallCeilingKbps` is
the ceiling of the recent stall on it, `null` when there is none. Read that
line before reading code. A later switch, from verification or a quality
change, logs a different line; see "Verification" and "The switch".

The viewer's choice is Auto (the default), Original, or a fixed rung. Auto
direct plays or copies when the rules below allow it, and otherwise
transcodes at the source resolution, like Original, unless a recent stall on
the current link path says the file will not fit, in which case it asks for
the highest adaptive rung that does. Knowing nothing about the connection is
not evidence against it, so a play with no recent stall on its path tries
the file's own bytes, or transcodes uncapped when it cannot. A fallback after
a playback failure is a different case: under Auto it steps down deliberately
rather than waiting for evidence (`fallbackPlan`; see "Verification" below).
Original is the viewer's override: it bypasses remembered decode failures and
recent stalls, wherever that choice came from. A fixed rung pins its own caps
and always transcodes, skipping both checks below.

Three rules, in order, decide between direct play, copy and transcode for
Auto and Original alike. Direct play needs native, a leading DIRECT_PLAY or
REMUX, and no fixed rung chosen; for Auto it also needs a bitrate that fits,
with 30% headroom, the ceiling of any recent stall on the current link path.
Copy needs a non-leading HLS_COPY, the same bitrate condition for Auto, and
on web a MIME string `MediaSource.isTypeSupported` accepts. Otherwise
transcode.

A shape known to fail here (the failure memory below) also blocks direct play
and copy for Auto; picking Original in the quality menu tries it anyway,
whether that choice was just tapped, seeded from storage, or carried over
from the previous episode. A recent stall has the same carve-out: Original
plays the file's own bytes on any link, and buffers if the link cannot keep
up.

The stored `default_quality` key: `auto` reads back as Auto, `original` as
Original. Before the Auto rung existed, Original was the default and was
itself stored under the `auto` key, so an existing install's stored
preference now reads as Auto rather than Original.

A leading HLS_COPY is the server's `:needs_transcoding` verdict and is never
taken; see `lib/mydia/streaming/README.md`.

### Stalls, not a throughput estimate

The only bandwidth evidence Auto acts on is a stall that forced a fallback. A
bandwidth fallback records one `StallRecord` for the link path in use at that
moment: `direct`, `relay` or `mixed` over p2p, `http` otherwise, and nothing
while a p2p connection has no peer path. Its ceiling is the throughput read
while the source stalled, capped at 90% of the file's bitrate, or that cap
alone when the reading is missing or zero (`stallCeilingKbps`). A newer stall
on the same path replaces it, and it lapses after an hour, so a link that
recovers, or a relayed path that goes direct, gets a direct play attempt on
the next file. A weak link pays the verification window once an hour rather
than never being tried.

An earlier revision kept a running average of mpv's `cache-speed`, sampled
once a minute during clean playback, and gated direct play on it. That
reading measures consumption, not capacity: once mpv's demuxer cache is full
(media_kit's 32 MB default), mpv reads only as fast as playback drains it.
The average therefore converged on the bitrate of whatever Auto last played,
and with the 30% headroom it then refused direct play of files the link
carried without trouble, including the file it had just direct played. A
reading taken while a source stalls does not have this problem, since the
cache is draining then. Do not bring back an estimate built from
clean-playback samples.

## Verification

A direct play or copy source is watched for its first 20 seconds of playing
time. A fault before the first frame, more than one dropped frame a second
over 10 seconds, two stalls, or 15 seconds of a draining buffer under 10
seconds ahead replace it with a transcode at the same position, on the same
`Player`. Afterwards the drain check stays as is, but stalls and drops get
looser: three stalls in two minutes, or three consecutive 10-second windows
each over the drop limit. The numbers live in `AdaptationThresholds`.

The stall and drain rules act only when Auto is the choice
(`AdaptationPolicy.reactsToBandwidth`). Under Original only the fault and
dropped-frame rules can replace the source: the viewer asked for the file's
own bytes, and a slow link buffers rather than being swapped for a
transcode. Throughput is still measured either way. A quality pick that
delivers the same bytes reopens nothing and keeps the running policy, so the
pick flips that flag on it rather than starting a new one: media_kit's
streams do not replay, and a monitor created mid-playback would never see
playback as started.

A stall only counts once playback has run. media_kit reports buffering from
mpv's `start-file` until the file loads, and `play()` has been called by then,
so the open's own loading looks exactly like a stall; a 4K MKV with 38 MB of
embedded fonts spends seconds there. Nor does a stall that starts within 10
seconds of a track switch or seek: switching subtitle track makes mpv reopen
the byte range from the first cluster and pause for cache while it catches
up. The screen notes a track switch with the monitor just before asking
media_kit for it (`_setAudioTrack`, `_setSubtitleTrack`), as `seekToReal`
does for seeks, so the switch is on record before the rebuffer it causes;
`player.stream.track` still catches a switch the screen did not start.
Before both rules, opening such a file and picking its English subtitles was
two stalls, and a fallback for "your connection".

This kind of switch logs its own line, not the `Plan:` line above:
`[PlayerScreen] Falling back to <plan>: <reason> at <n>s (<detail>)`.
`<plan>` is the fallback's own `describe()` (always ends
`(fallbackFromFailure)`, since `fallbackPlan` only ever builds that reason);
`<reason>` is the `FailureReason` that triggered it (`decodeFailed`,
`decodeTooSlow` or `bandwidth`); `<n>s` is the position it switched at;
`<detail>` names the rule and what it saw, such as
`bandwidth: 2 stalls at 3s, 9s; last interruption 9s`. Times inside
`<detail>` are monitor time since verification started, not positions.

A decode fallback always records the file's shape (RFC 6381 video codec plus
height bucket) against the server, regardless of the quality choice in play.
Whether that record is later consulted follows the same rule as "The
decision": a remembered shape skips direct play and copy for Auto on the next
play, and Original bypasses it regardless of where that choice came from. A
bandwidth fallback, which only Auto can trigger, records a stall for the
current link path (see "Stalls, not a throughput estimate"), and Auto
consults it on the next play over that path within the hour; Original
ignores it. There is no control to clear the box: a remembered shape expires
after 14 days and a stall after an hour, and Original skips both before
then.

## The switch

`PlaybackController.replaceSource` starts the new session, hands the source
to the screen's `_attachSource`, waits for the position stream to advance
(60 s bound), then ends the old session. Native opens the new media on the
live `Player`. Web disposes and recreates it: media_kit 1.2.6's web backend
stacks an hls.js instance per `open()` and never destroys the old one.

Verification only arms once the switch has landed, that first advance, on
both platforms: a fault on the incoming source before then surfaces as an
error page rather than a fallback, and a fallback requested while a switch is
already in flight is silently dropped rather than queued.

Seeks past a WINDOW playlist (servers older than full-playlist support) and a
quality change that needs different bytes use the same switch. There is no
restart path.

A switch keeps the viewer's subtitle choice. Opening the new file drops any
subtitle mpv was given with `sub-add`, and media_kit resets its own record of
the selection, so `_switchSource` captures the choice before the old file goes
away and `_restoreSubtitleIntent` applies it again once the switch lands. A
sidecar comes back from the body already fetched. An embedded stream is
matched across Original and a transcode by its ffprobe stream index, which is
both the server's track id and mpv's `ff-index`, with the language tags as a
cross-check. An image track (PGS, VobSub, DVB, XSUB) comes back on native as a
bitmap sidecar: the server stream-copies it into `subs_<index>.mks` in the
session, and the player polls through the server's 503s, saves the file and
`sub-add`s the local copy (`image_subtitle_sidecar.dart`). On web, or against
a server too old to serve one, subtitles turn off with a toast saying so.
An explicit Off is applied
again; a viewer who never touched subtitles gets no call at all, so mpv keeps
the defaults it uses on a fresh open. Subtitle picks are ignored while a
switch is in flight, the same way quality picks are.


A subtitle call already on its way when a switch starts, such as the restore
from the switch before or a pick still fetching its body, waits for the switch
to finish and then drops itself if the switch superseded it. The switch in turn
waits for a subtitle call already running before it replaces the file, so
neither reaches a player that is being disposed (web) or is opening another
file (native). `SourceSwitchGate` holds both rules. A failed switch supersedes
nothing, so a pick it held back still lands on the source that stayed. Two
callers wanting the same subtitle body while it is still fetching share one
request, so the server extracts it once.


The quality picker offers Auto above Original, then the ladder
`deriveQualityLadder` builds for the source. Auto's subtitle names what it is
doing right now: `Auto · Direct Play`, `Auto · Original, no re-encoding`, or
`Auto · <rung>` for a transcode (`Auto · Original, re-encoding required`
mainly when nothing says the connection cannot carry the file, since that is
when Auto transcodes uncapped; also when the adaptive ladder has nothing to
offer for this source). Settings shows the same Auto row with the neutral
`Adapts to your connection`, since there is no plan to describe there.

A quality change logs `[PlayerScreen] Quality change: <plan>` and switches,
unless the new plan delivers the same bytes as what is already playing:
`sameDelivery` compares both plans as direct play, or the same HLS strategy
at the same rung, ignoring the reason and the adaptive flag. Auto and
Original often agree on a lossless file, and picking one over the other then
changes nothing about what is on screen. That case does not reopen the
source; it only updates which choice is selected, and logs
`[PlayerScreen] Quality change: <plan> (already playing)` instead.

A fallback (see "Verification" above) keeps the viewer's choice. Under Auto
it lands on `fallbackPlan`'s stepped-down adaptive rung and stays Auto. Under
Original it lands on a transcode at the source resolution with no caps, still
labelled Original. Neither writes the stored default: one file failing here
says nothing about the next. Auto does not change rung again on its own
mid-session; that needs a server-side rendition switch, not built yet.

## Which HLS engine plays it on web

hls.js, always, whenever it can run. Not the browser's own HLS engine, and
this is not a preference: a Mydia session is unplayable by one.

A `:full` session publishes every segment of the file in its playlist before
an encoder has reached them, answers `503` with `Retry-After` for one that is
not ready (`hls_controller.ex`), and relocates its encoder mid-flight when the
viewer resumes, so segments arrive from more than one FFmpeg run. hls.js and
mpv retry and carry on. A browser's engine stops: measured on 2026-09-19, a
session resumed at 4:23 froze within ten seconds and never recovered, on iOS
Safari against production and in Chromium's own HLS locally, while the same
file from 0:00 played fine and the same resumed session played straight
through with hls.js in the path. The freeze reads as a stuck spinner with a
full buffer, and progress keeps saving the resume position forever.

media_kit chooses the browser's engine for anything answering
`canPlayType('application/vnd.apple.mpegurl')` non-empty, which is every
WebKit browser and desktop Chromium since 143, and it exposes no knob. So
`core/player/hls_engine.dart` takes the knob: it loads a current hls.js from
`web/hls/` (media_kit bundles 1.4.10, which predates `ManagedMediaSource` and
therefore cannot run on iPhone at all) and then answers `''` for HLS content
types, but only while `Hls.isSupported()` is true. On iOS Safari below 17.1,
which has neither `MediaSource` nor `ManagedMediaSource`, nothing is hidden
and the browser's engine stays the only path there is.

Two consequences worth knowing. The `httpHeaders` media_kit is given only
reach the wire on the hls.js path, through its `xhrSetup`; the browser's
engine drops them and the session rides on the cookie instead. And
`CodecSupport.prefersNativeHls` reads the same patched `canPlayType`, so it
reports the browser's own claim only before `prepareHlsEngine` has run, or in
a browser where hls.js cannot run. Once the override is in place it answers
false, which keeps it true to its name: media_kit is no longer reaching for
the browser's engine.

## Compatibility

Old player, new server: unchanged, byte for byte. New player, old server:
the legacy `startStreamingSession` document on a server that rejects the
`maxHeight` or `playlistMode` argument or field, remembered per connection in
`ServerFeatures`.

## Testing

`flutter test` cannot construct a native `Player`, so the screen's playback
path ends in the error state under test. The decision, the policy and the
controller are therefore tested as units: scripted candidates, scripted
`HealthSample`s, and, in `playback_controller_test.dart`, a `StubLink` with a
fake `attach` callback standing in for the screen. Screen tests assert on the
requests that reach the wire.

## Stats for nerds

A device-level flag (`stats_overlay_enabled`, exposed as
`statsOverlayEnabledProvider`) draws `StatsPanel` over the video. There is no
chrome button for it: `SecondaryCluster` already runs at a measured overflow
floor (`chrome_panel_overflow_test.dart`), so the two entry points are the
settings row and a row `showQualityPicker` adds at the foot of the quality
sheet, since that is where a viewer already stands when wondering why the
picture looks soft.

The panel is fed by two things kept deliberately apart. `buildStatsContext`
composes a `StatsContext` from the plan, the selected tracks and the p2p
status; `PlaybackStatsCollector` samples `FrameStatsSampler` once a second
into a `StatsSample` with a 60-point history. `PlaybackStatsCollector` is
deliberately not `PlaybackMonitor`. `_startVerification` arms the monitor
only for a server-backed, non-cast source (a downloaded file skips it via
`_isDownloadedSource`; a cast session never reaches `_startVerification` at
all, since `_buildBody` branches to the cast placeholder first), its
dropped-frame figure is a delta whose baseline resets per verification
generation, and its lifetime is a verification window, not a playback
session. Arming it more widely would change what `AdaptationPolicy`
observes. The collector instead borrows `FrameStatsSampler` one layer down,
which already returns cumulative counters, already has native, web and stub
implementations, and already answers null on a failed property read rather
than zero.

`StatsMetrics.tvMinHeight`, `fullMinHeight` and `compactMinHeight` are
minimums: the least available height worth drawing a density in, never a
height the panel renders at. An earlier revision declared rendered heights
and could not make them hold, because the Why row's text length varies with
the adaptation reason and rows appear or disappear with what the platform
can report. The panel sizes to its content and scrolls the row region
(`Flexible` plus `SingleChildScrollView` inside `StatsPanel.build`) once
content exceeds the box; the header, the divider, the compact footnote and
the remote hint stay pinned outside that scroll region.

`tvMinHeight` (589) is set to the tv panel's own measured content height on
purpose, so a television never scrolls its stats: a D-pad cannot scroll an
unfocusable scroll view, and the remote tier deliberately draws no
focusable controls at all. It also has to stay above 412, the available
height `stats_metrics_test.dart` gives a 1280x650 D-pad viewport, or that
viewport would resolve to the tv density instead of falling through to
full, breaking the test that asserts the fallthrough.

Every row's height is a function of font and density alone, never of the
string. That is why `StatsPanel._row` lays the pill and value out in a
`Row` with the value wrapped in `Flexible`, not a `Wrap`: a `Wrap` can push
the value onto a second line when it and the pill do not both fit, which
makes the row's height depend on the string currently in it. `Flexible`
keeps the pill and value on one line always, ellipsizing an overlong value
instead of reflowing it. This is load-bearing for the tv tier's "never
scrolls" guarantee above, which only holds if every row, not just the ones
drawn at tv density, has a height fixed by font and density alone.

A row with no value is omitted, never dashed (`statsRows` in
`stats_report.dart`): a dash beside a label reads as a fault in the player,
not as "nothing to report," and the copy payload carries the field either
way. `whyDetail`, the raw string `AdaptationPolicy` already builds for its
own `debugPrint`, reaches `statsClipboardText` and the clipboard only; it
never becomes a row. That split, a one-sentence `why` on screen and the
full detail one copy away, is what justifies the copy button existing at
all.

`PlaybackStatsCollector.rebind()` is called once, inside `_switchSource`,
rather than at each of its three call sites (a fallback, a quality change,
a seek restart past a WINDOW playlist). Without it, the next sample after a
switch diffs the new source's cumulative dropped-frame count against the
previous source's baseline and reports a spike that never happened. Calling
it centrally means a future switch path inherits the reset without the
caller having to remember it.

`_lastFallback` is cleared on a genuinely fresh media item but preserved
across a fallback's own source switch (the `isSourceSwitch` guard in
`_initializePlayer`). `go_router` keys the player page by route pattern, not
the resolved path, so navigating to the next episode of a season reuses the
same `PlayerScreen` state rather than rerunning `initState`, which is
exactly the moment a stale Why message would otherwise outlive the file it
explained if the clear were unconditional.

Known gap, left as is rather than patched: a 1280x720 television leaves
482px of available height (720 minus the 64px top inset minus the desktop
tier's 174px corner inset), which is below `tvMinHeight` (589). A common
Android TV resolution therefore resolves to the `full` density and draws
11.5px label text meant for a desk, not a couch across the room. Fixing it
properly means letting the remote tier keep tv typography while showing
fewer rows at short viewports, a fourth density rather than a constant
change, and it has not been built.

One more thing worth knowing before trusting a height measured in
`flutter test`: this repo has no `flutter_test_config.dart` calling
`loadAppFonts()`, so tests render text with Flutter's fallback test font,
whose glyphs run noticeably wider than the real ones. A layout that is
text-driven, like this panel's rows before the scroll fix above, measures
taller in a test than it ever renders on a device.

## The subtitle a show opens on

The media-file document carries `preferredSubtitle`: mode `OFF` for an
explicit off, `TRACK` with a language and its flags for a track to find, and
nothing at all for no opinion. `subtitle_preference.dart` turns that into a
preference, and `_applySubtitlePreference` runs off a track-list revision
rather than from `_initializePlayer`, because the list is what it matches
against and in direct play that list is mpv's, published asynchronously after
`open()`. Nothing is spent when there is nothing to apply to: a descriptor
that matches no track, or a revision arriving before there is a player, leaves
`_preferenceAppliedForPlayback` unset so the next revision still gets its
chance. It is set before the await rather than after, because media_kit
revises its track list several times per playback and a revision landing
mid-apply would otherwise race the first one.

The match is ranked, not filtered. Language has to agree first —
`subtitlePreferenceLanguageEquals`, which folds ISO 639-2/B against /T because
Matroska writes one form and ffprobe the other, and which refuses `und` and an
empty tag. Deliberately not `subtitleLanguagesCompatible` from the track
builder: that one treats `und` as compatible with anything, which is right for
carrying a known track across a quality switch and wrong here, where it would
attach every untagged track to every preference. Then forced (+8),
hearing-impaired (+4) and the remembered title (+2), with a non-forced track
taking a tie (+1) so an unflagged list still resolves to the full-dialogue
track rather than the signs-only one. Forced weighs most because it is the flag
that decides whether the viewer sees the episode or only its foreign dialogue.

Two things make a partial match normal rather than exceptional. An mpv-native
track reports no disposition at all — media_kit publishes its language and
title and nothing else — so a pick on one is translated through its stream
index to the server's own track, which does have the flags, and a track that
cannot be translated stores its language and title with both flags false; the
title tiebreak is what resolves it on the next episode. And a season whose
files disagree about SDH tagging should still keep showing the viewer's
language, which it does.

**An applied preference is not written back.** It is a choice being restored,
not a new one, so only a pick the viewer made — the sheet's tile, or a remote
`selectTrack` — reaches `_rememberSubtitlePreference`, and only once the apply
has returned and the selection is still the one showing. Writing a restore
back would let the first episode whose track list lacks the remembered title
degrade what is stored for the rest of the show. An explicit Off is a
selection like any other and is remembered as one; it also has to be applied
rather than left alone, since mpv's own default-disposition pick is exactly
what switches a subtitle on unasked in direct play.

The preference is refetched with each file's media-file document rather than
carried in memory, so an episode change needs no handoff. A quality switch is
a different case and does carry the current choice; see "The switch".

## Who draws subtitles

media_kit builds `Player()` with `libass: false`, which sets mpv's
`sub-visibility=no`: mpv draws nothing, and media_kit_video's `SubtitleView`
draws `sub-text` instead. `sub-text` is text, so a bitmap track (PGS, VobSub,
DVB, XSUB) showed nothing, in direct play as much as when streaming.
`subtitle_render.dart` watches mpv's own `current-tracks/sub/codec` and turns
`sub-visibility` on while a bitmap track is active, off for text, so the two
renderers never draw the same track and Android needs no libass font asset.

It has to be mpv's property. media_kit's `stream.track` records a `sub-add`ed
track exactly as the app handed it over, with no codec, and never hears about
a default track mpv selects on its own when a file opens.

### On web, the browser draws them

None of the above applies in the browser, where there is no mpv and
`SubtitleView` is fed by a handler that cannot work. media_kit attaches a
picked track to the `<video>` as a `<track>` child, leaves it `hidden`, and
pushes cues to Flutter from its own `cuechange` listener, which reads
`activeCues.dartify` without calling it and throws `NoSuchMethodError` on
every cue (its author marked it "UNTESTED"). Measured 2026-09-19: the track
attaches, all 1080 cues parse, one is active at the right moment, and the
screen stays blank.

`subtitle_cues.dart` hands the drawing to the browser instead. After a pick
takes effect it disables every text track on the element and shows the last
one, which is the one media_kit just appended; after "Off" it disables them
all. That second half is not symmetry for its own sake: media_kit does
nothing at all for `SubtitleTrack.no()` on web, so without it subtitles could
be turned on and never off again. It also drops media_kit's `cuechange`
listener from the track it shows, which is what stops a `NoSuchMethodError`
per cue reaching the console for the length of a film.

Cues are drawn in the browser's own style, and the player has no subtitle
appearance settings to honour, so nothing is lost there today. They sit at the
bottom of the video, where the OSD covers them while it is up.

