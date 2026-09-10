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

Every plan logs one line: `[PlayerScreen] Plan: <plan> shape=<codec>/<bucket>
bitrateKbps=<n> throughputKbps=<n>`, where `<plan>` is `directPlay (<reason>)`
for a direct play, or `<strategy> <rung> (<reason>)` for an HLS plan (copy or
transcode carry a rung; direct play does not). The reason names the rule from
the spec that fired. Read that line before reading code.

Three rules, in order. Direct play needs native, a leading DIRECT_PLAY or
REMUX, no fixed rung chosen, and a bitrate that fits remembered throughput
with 30% headroom. Copy needs the same bitrate condition plus a non-leading
HLS_COPY, and on web a MIME string `MediaSource.isTypeSupported` accepts.
Otherwise transcode.

A shape known to fail here (the failure memory below) also blocks direct play
and copy, but only when the request is the Auto choice; a manually chosen
Original bypasses it and always retries. The quality picker has no Auto row
yet (a later phase), so today's two reachable choices are Original, which
always retries direct play and copy regardless of memory, and a fixed rung,
which skips straight to transcode. The bandwidth check has no such carve-out:
it applies to every choice, Original included.

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

A decode fallback always records the file's shape (RFC 6381 video codec plus
height bucket) against the server, regardless of the quality choice in play.
Whether that record is later consulted follows the same Auto/Original split
as "The decision": only a session planned as Auto skips a shape already known
to fail, so this only takes effect once Auto ships. A bandwidth fallback
lowers the remembered throughput, and that check applies unconditionally, so
a slow link is remembered on the very next attempt regardless of choice.
Settings has a "Forget playback problems" row that clears the box.

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

Seeks past a WINDOW playlist (servers older than full-playlist support) and
manual quality changes use the same switch. There is no restart path.

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
