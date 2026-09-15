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
transcodes at the source resolution, like Original, unless remembered
throughput says the file will not fit, in which case it asks for the highest
adaptive rung that does. Knowing nothing about the connection is not evidence
against it, so a first play, and every web play (web never measures
throughput), transcodes uncapped. A fallback after a playback failure is a
different case: under Auto it steps down deliberately rather than waiting for
evidence (`fallbackPlan`; see "Verification" below). Original is the viewer's
override: it bypasses remembered decode failures and remembered throughput,
wherever that choice came from. A fixed rung pins its own caps and always
transcodes, skipping both checks below.

Three rules, in order, decide between direct play, copy and transcode for
Auto and Original alike. Direct play needs native, a leading DIRECT_PLAY or
REMUX, and no fixed rung chosen; for Auto it also needs a bitrate that fits
remembered throughput with 30% headroom. Copy needs a non-leading HLS_COPY,
the same bitrate condition for Auto, and on web a MIME string
`MediaSource.isTypeSupported` accepts. Otherwise transcode.

A shape known to fail here (the failure memory below) also blocks direct play
and copy for Auto; picking Original in the quality menu tries it anyway,
whether that choice was just tapped, seeded from storage, or carried over
from the previous episode. Remembered throughput has the same carve-out:
Original plays the file's own bytes on any link, and buffers if the link
cannot keep up.

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

The stall and drain rules act only when Auto is the choice
(`AdaptationPolicy.reactsToBandwidth`). Under Original only the fault and
dropped-frame rules can replace the source: the viewer asked for the file's
own bytes, and a slow link buffers rather than being swapped for a
transcode. Throughput is still measured either way.

A stall only counts once playback has run. media_kit reports buffering from
mpv's `start-file` until the file loads, and `play()` has been called by then,
so the open's own loading looks exactly like a stall; a 4K MKV with 38 MB of
embedded fonts spends seconds there. Nor does a stall that starts within 10
seconds of a track switch or seek: switching subtitle track makes mpv reopen
the byte range from the first cluster and pause for cache while it catches
up. The monitor learns of track switches from `player.stream.track` and of
seeks from `seekToReal`. Before both rules, opening such a file and picking
its English subtitles was two stalls, and a fallback for "your connection".

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
bandwidth fallback, which only Auto can trigger, lowers the remembered
throughput, and Auto consults it on the very next attempt; Original ignores
it. There is no control to clear the box: a remembered shape expires after
14 days, Original skips it before then, and remembered throughput keeps
updating from what playback measures.

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
