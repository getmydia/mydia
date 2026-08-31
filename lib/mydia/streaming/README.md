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
