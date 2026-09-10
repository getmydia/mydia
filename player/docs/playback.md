# Playback: who decides what plays

The server answers "what can this device play" through `streamingCandidates`.
Everything after that is the player's, in `lib/core/playback/`:

| Unit | Job |
| --- | --- |
| `planPlayback` (`playback_planner.dart`) | candidates plus memory in, `PlaybackPlan` out. A top-level function, not a class. Pure. |
| `fallbackPlan` (`playback_planner.dart`) | the adaptive transcode a fallback lands on: source height and remembered throughput in, an `HlsPlan` out. Also a function. Pure. |
| `PlaybackMemory` | per server: file shapes that failed to decode here (14 days), and an EWMA of throughput. An abstract class; `HivePlaybackMemory` backs the app, `InMemoryPlaybackMemory` backs tests. |
| `PlaybackMonitor` | one `HealthSample` a second from media_kit's streams and the engine's frame counters (mpv's properties on native, the video element's on web) |
| `AdaptationPolicy` | the sample window in, `FallbackToTranscode` out. Pure state machine. |
| `PlaybackController` | starts and ends sessions, and replaces a source on the live `Player` |

`PlayerScreen` builds the inputs, calls the controller, and renders what it
reports. It does not read the candidate list itself.

## The decision, and where to look when it is wrong

The initial decision, made once when a file starts, logs one line:
`[PlayerScreen] Plan: <plan> shape=<codec>/<bucket> bitrateKbps=<n>
throughputKbps=<n>`, where `<plan>` is `directPlay (<reason>)` for a direct
play, or `<strategy> <rung> (<reason>)` for an HLS plan (copy or transcode
carry a rung; direct play does not). The reason names the rule that fired.
Read that line before reading code. A later switch, from
verification or a quality change, logs a different line; see
"Verification" and "The switch".

The viewer's choice is Auto (the default), Original, or a fixed rung. Auto
direct plays or copies when the rules below allow it, and otherwise
transcodes at the top rung of the adaptive ladder that fits remembered
throughput (the top rung when throughput is unknown). Original is the
viewer's override: it bypasses remembered decode failures, wherever that
choice came from. A fixed rung pins its own caps and always transcodes,
skipping both checks below.

Three rules, in order, decide between direct play, copy and transcode for
Auto and Original alike. Direct play needs native, a leading DIRECT_PLAY or
REMUX, no fixed rung chosen, and a bitrate that fits remembered throughput
with 30% headroom. Copy needs the same bitrate condition plus a non-leading
HLS_COPY, and on web a MIME string `MediaSource.isTypeSupported` accepts.
Otherwise transcode.

A shape known to fail here (the failure memory below) also blocks direct play
and copy for Auto; picking Original in the quality menu tries it anyway,
whether that choice was just tapped, seeded from storage, or carried over
from the previous episode. The bandwidth check has no such carve-out: it
applies to every choice, Auto and Original alike.

The stored `default_quality` key: `auto` reads back as Auto, `original` as
Original. Before the Auto rung existed, Original was the default and was
itself stored under the `auto` key, so an existing install's stored
preference now reads as Auto rather than Original.

A leading HLS_COPY is the server's `:needs_transcoding` verdict and is never
taken; see `lib/mydia/streaming/README.md`.

## Verification

A direct play or copy source is watched for its first 20 seconds of playing
time. A fault before the first frame, more than one dropped frame a second
over 10 seconds, two stalls, or 15 seconds of a draining buffer under 10
seconds ahead replace it with a transcode at the same position, on the same
`Player`. Afterwards the drain check stays as is, but stalls and drops get
looser: three stalls in two minutes, or three consecutive 10-second windows
each over the drop limit. The numbers live in `AdaptationThresholds`.

This kind of switch logs its own line, not the `Plan:` line above:
`[PlayerScreen] Falling back to <plan>: <reason> at <n>s`. `<plan>` is the
fallback's own `describe()` (always ends `(fallbackFromFailure)`, since
`fallbackPlan` only ever builds that reason); `<reason>` is the
`FailureReason` that triggered it (`decodeFailed`, `decodeTooSlow` or
`bandwidth`); `<n>s` is the position it switched at.

A decode fallback always records the file's shape (RFC 6381 video codec plus
height bucket) against the server, regardless of the quality choice in play.
Whether that record is later consulted follows the same rule as "The
decision": a remembered shape skips direct play and copy for Auto on the next
play, and Original bypasses it regardless of where that choice came from. A
bandwidth fallback lowers the remembered throughput, and that check applies
unconditionally, so a slow link is remembered on the very next attempt
regardless of choice. Settings has a "Forget playback problems" row that
clears the box.

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

The quality picker offers Auto above Original, then the ladder
`deriveQualityLadder` builds for the source. Auto's subtitle names what it is
doing right now: `Auto · Direct Play`, `Auto · Original, no re-encoding`, or
`Auto · <rung>` for a transcode (`Auto · Original, re-encoding required` when
the adaptive ladder has nothing to offer for this source). Settings shows the
same Auto row with the neutral `Adapts to your connection`, since there is no
plan to describe there.

A quality change logs `[PlayerScreen] Quality change: <plan>` and switches,
unless the new plan delivers the same bytes as what is already playing:
`sameDelivery` compares both plans as direct play, or the same HLS strategy
at the same rung, ignoring the reason and the adaptive flag. Auto and
Original often agree on a lossless file, and picking one over the other then
changes nothing about what is on screen. That case does not reopen the
source; it only updates which choice is selected, and logs
`[PlayerScreen] Quality change: <plan> (already playing)` instead.

A fallback (see "Verification" above) always lands the session on Auto for
the rest of the playback, in memory only: the stored default is the viewer's
own preference, and one file failing to decode here says nothing about the
next, so a fallback never writes it. Auto does not change rung again on its
own mid-session; that needs a server-side rendition switch, not built yet.

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
