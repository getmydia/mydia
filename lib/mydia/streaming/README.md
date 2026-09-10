# Streaming: where codec data actually lives

## Read metadata.streams, not the flat FileMetadata fields

`Mydia.Library.Structs.FileMetadata` declares flat codec-detail fields
(`hevc_profile_idc`, `video_profile_idc`, `video_level_idc`, `bit_depth`), and the
analyzer never writes any of them. Measured on the galactica production library
across all 1291 non-trashed HEVC rows:

| source | populated |
| --- | --- |
| `metadata.hevc_profile_idc` | 0 / 1291 |
| `metadata.bit_depth` | 0 / 1291 |
| `metadata.streams[0].bit_depth` | 1291 / 1291 |
| `metadata.streams[0].level` | 1291 / 1291 |

Always read `metadata.streams` (`Mydia.Library.Structs.StreamInfo`) for profile,
level, bit depth, resolution, frame rate, channels and sample rate. A
compatibility or quality check sourced from the flat fields resolves to nil
everywhere and, unless it fails closed, approves everything while looking like it
validates. It also passes its own tests if the fixtures set the flat fields.

`StreamInfo` carries `profile` ("Main 10"), `level` (120), `bit_depth`,
`pixel_format`, `width` and `height`, `frame_rate`, the `color_*` fields,
`dolby_vision_profile`, `channels`, `channel_layout` and `sample_rate`.

Library composition worth knowing: 1220 of 1291 HEVC files are Main 10 (94.5%),
70 are 8-bit Main, and 1 is 12-bit RExt. Any rule pushing 10-bit HEVC to
transcoding moves almost the entire HEVC catalogue.

## codec_string.ex only ever takes the derived branch

`lib/mydia/streaming/codec_string.ex` has two branches for every video codec. One
uses raw ffprobe integers (`video_profile_idc`, `video_level_idc`,
`video_constraint_set`, `hevc_profile_idc`, `hevc_tier_flag`, `hevc_level_idc`,
`vp9_profile`, `vp9_level`, `av1_profile`, `av1_level`, `av1_tier`, `bit_depth`),
and the other derives everything from the human-readable profile name.

Nothing ever populates those integers. They are declared on the `FileMetadata`
struct and read in `codec_string.ex`, and that is all. `file_analyzer.ex` does not
write them. So the Elixir server always takes the derived branch, and every H.264
file gets level 40 (0x28) while every HEVC file gets level_idc 120, regardless of
what the file actually is.

Verify with `grep -rn "video_profile_idc" lib/ --include=*.ex`, which returns two
hits, both listed above. Any port of this module only needs the derived branch;
adding the raw branch would make the port answer differently from the server it is
measured against by the conformance suite.

## A leading HLS_COPY encodes :needs_transcoding

`Mydia.Streaming.Candidates.build_streaming_candidates/2` returns a
priority-ordered list, and the leading entry encodes the server's
`check_compatibility/2` verdict:

| verdict | list shape |
| --- | --- |
| `:direct_play` | `[DIRECT_PLAY, TRANSCODE]` |
| `:needs_remux` | `[REMUX, HLS_COPY, TRANSCODE]` |
| `:needs_transcoding` | `[HLS_COPY…, TRANSCODE]` (one per codec variant) |

`HLS_COPY` in front means `:needs_transcoding`. `HLS_COPY` behind a `REMUX` is
genuine, because in the remux branch the codecs are already known compatible and
only the container is not.

`HLS_COPY` repackages without re-encoding, so it always carries the original video
codec and can never turn an incompatible codec into a compatible one. Anything
treating a leading `HLS_COPY` as playable inverts the server's verdict and hands
the client the exact bytes it just said it could not decode.

Three call sites had that bug at once, fixed 2026-08-25 in PRs #564 and #566:
`_canDirectPlay` and `_pickHlsStrategy` in `player_screen.dart`, plus
`firstStrategyAllowsDirectPlay` in `domain/models/quality_delivery_subtitle.dart`,
which drives the Original-rung label and would have kept reading "Direct Play"
even after the playback gate was fixed. Grep for all three shapes before assuming
a candidate-list fix is complete.

The server now drops the `HLS_COPY` rungs when the client's declared conditions
reject the stream (`Compatibility.conditions_reject?/2`). Only conditions suppress
them, never a codec's mere absence from the allowlist. A codec missing from the
lists means the client never claimed it, which still leaves stream-copy on the
table for a browser that judges codec strings itself. Breaking that distinction
would silently force Safari to transcode HEVC.

Since 2026-09 the player no longer reads the candidate list in
`player_screen.dart`. `player/lib/core/playback/playback_planner.dart` holds
the three rules and `player/docs/playback.md` explains them. The server's
candidate shapes are unchanged; an old player against a new server behaves
exactly as before.

## Five deadlines sit between "play" and the first segment

Starting playback crosses up to five independent timeouts, in three languages.
They are not redundant, and changing one without reading the others produces a
failure that looks like the network.

| budget | where | covers |
| --- | --- | --- |
| 1.5s | `@timeout_ms`, `keyframe_locator.ex` | the keyframe lookup, only for a new `:window` stream-copy resume from MKV or MP4 |
| 25s | `@request_timeout`, `p2p/server.ex` | one GraphQL request, host side |
| 30s | `RESPONSE_TIMEOUT`, `mydia_p2p_core/src/lib.rs` | one GraphQL request, peer side |
| 2min | `@session_ready_timeout`, `p2p/server.ex` | FFmpeg writing its first playlist |
| 60s | `:timeout`, `Mydia.Repo` config | one query, *excluding* the pool checkout |

The database row is narrower than it looks. `:timeout` bounds the query itself.
Waiting for a pool connection is governed separately, by `:queue_target` (50ms)
and `:queue_interval` (2s), and neither is configured here. `:pool_timeout` does
not exist in db_connection 2.x at all, so the `pool_timeout: 60_000` still sitting
in `config/test.exs` is a dead option, not a longer budget.

That distinction has diagnostic value: an exhausted pool does not stall quietly,
it raises `connection not available and request was dropped from queue after Nms`.
A slow query with no such error in the log was never waiting on a checkout.

Two rules hold the p2p side together.

**The host's request deadline must stay under the peer's.** They were both 30s,
which raced: an overrunning request was abandoned by the peer at the same moment
the host decided to answer it, so the peer inferred a timeout from silence
instead of reading the error the host had prepared. `serve_request/5` exists to
guarantee exactly one answer goes back; equal deadlines defeated it.

**The readiness budget is not a request budget.** HLS bytes travel a separate
QUIC stream path (`stream_hls_response/3`), not the request/response path, so no
`RESPONSE_TIMEOUT` covers it and the peer waits as long as the host takes. That
budget therefore bounds only how long a dead encoder ties up a slot, and is sized
for the worst cold start rather than the typical one.

Which is why it runs under `Mydia.P2p.StreamSupervisor` rather than a bare
`Task.start`. iroh accepts an inbound connection on ALPN alone, so every request
against a session still warming up parks a task for the whole readiness budget
plus a waiter inside the session, and a two-minute budget is four times the
window a thirty-second one gave a peer to pile them up. The bound is what makes
the longer wait safe to have; stretch one without the other and the readiness
budget becomes a denial-of-service budget.

Observed on 2026-09-08 on the production instance: a viewer advanced to an AV1
episode, which needs a full software encode. FFmpeg took 29.6s to write a
playlist against the then-30s readiness budget, and `StartStreamingSession`
returned in 29,728ms against the peer's 30s. Both missed by under half a second,
in opposite directions.

Something else stretched the two GraphQL calls in front of the encoder, and it is
still unexplained. `StreamingCandidates` billed 14,955ms for work that measures
1ms when the same resolver is driven directly on the live node, and every slow
call that day finished within 30ms of a `media_import` commit. Three candidate
mechanisms were checked and none survives: `CandidatePromotion.commit_group`
opens a DB-only transaction, `MetadataEnricher` does its network work before the
transaction opens, and the pool was never exhausted (zero queue-drop errors in
24 hours, against a signature that cannot fail silently). `busy_timeout` reads 0
on a pooled connection despite `config/runtime.exs` asking for 30,000, which is
worth chasing on its own.

Resist raising `pool_size` as a reflex here. It was tried and withdrawn: with no
queue drops in the log there was no evidence the pool was ever the constraint,
and the change would have been a guess wearing a measurement's clothes.

The lasting lesson is that time-to-first-segment is a budget chain, not a single
number, and that a transcode preset is part of it: `veryfast` is the default in
`ffmpeg_hls_transcoder.ex` because a preset chosen for offline encoding spends
wall clock the viewer is sitting through.

## Seeking with copied streams

Every resume and relocation seeks with `-ss` before `-i`, so FFmpeg starts
reading at a keyframe at or near the target. What the viewer gets depends on
which streams are copied. Measured with FFmpeg 8.1 on a source with a keyframe
every 10s:

| video | audio | stream begins | handled by |
| --- | --- | --- | --- |
| encoded | encoded | at the target | accurate seek, FFmpeg's default |
| encoded | copied | at the target | `-copypriorss:a 0` |
| copied | either | at the keyframe | `KeyframeLocator` and `:seek_keyframe`, `:window` only |

Copied audio skips the decoder, so accurate seek never trims it. Without
`-copypriorss:a 0`, a resume at 27s into a file with keyframes at 20 and 30
carried 7.2s of audio ahead of its first frame. Jellyfin fixed the same bug
with an output-side `-ss`. Under `-copyts` that rebases every timestamp to
zero, which would break `:full`, so it is not used here.

Where a copy seek lands depends on the container:

- MKV seeks back to the keyframe at or before the target.
- MP4 does too, but compares decode timestamps. A keyframe with B-frames
  behind it decodes a little before it displays (a quarter second on the
  source measured), so a target inside that window lands on that keyframe,
  just after the target. The lookup reports it either way.
- MPEG-TS has no seek index. A copy lands after the target and an ffprobe
  lookup lands mid-GOP, so TS sessions are never pinned and echo their
  requested offset.

FFmpeg also pulls every input seek back by 3/23s when the video has B-frame
delay and the container cannot seek by PTS. Seeking to a keyframe's exact
timestamp in an MKV therefore lands a whole GOP early: `-ss 20.001` against a
keyframe at 20.000 started at 10. A pinned keyframe is sought at
`keyframe + 0.2` for that reason.

A `:full` session's first encoder starts on the segment grid, like every
relocated one. Started at the raw resume second, forced keyframes follow the
start instead: resumed at 30s, the segments declared as 28-32, 32-36 and 36-40
began at 30.00, 33.92 and 37.93.

`hls_seek_alignment_integration_test.exs` re-measures all of this against the
installed FFmpeg. It is tagged `:ffmpeg`, so run it with `--include ffmpeg`
after any FFmpeg upgrade.
