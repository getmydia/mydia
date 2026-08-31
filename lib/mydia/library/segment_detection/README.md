# Segment detection: fpcalc

## fpcalc truncates to 120s without -length

Chromaprint's `fpcalc` has a `-length SECS` option defaulting to 120. Without an
explicit `-length`, it fingerprints only the first 2 minutes of the input, silently
drops the rest, and exits 0.

`DURATION` in its output is the duration of the input audio, not of the portion
actually fingerprinted, so the natural-looking self-calibration
`frame_ms = duration_ms / frame_count` is wrong whenever truncation happens.

Measured on a 10-minute window on 2026-08-03 with chromaprint 1.6.0:

| | without `-length` | with `-length` |
|---|---|---|
| frames | 948 | 4695 |
| derived frame_ms | 614.98 | 124.17 |
| episode pairs matching | 0 of 6 | 6 of 6 |

A correct run is about 124.17 ms/frame, roughly 8.05 fps. A `frame_ms` near 600
means `-length` is missing or too small.

Invoke as `fpcalc -raw -length <window_seconds + 1> <wav>`. When the WAV handed to
fpcalc contains only the decoded window, `DURATION` equals the fingerprinted span
and `duration_ms / frame_count` is correct.

This bit the intro/credits detection design, which specified the
`duration_ms / frame_count` calibration without the `-length` flag.
