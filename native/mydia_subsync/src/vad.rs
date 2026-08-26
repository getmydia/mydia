//! Speech detection over raw PCM.
//!
//! Mirrors alass-cli's approach: 10ms frames at 8kHz through libfvad, then
//! run-length encoded into spans, then short spans dropped. The constants here
//! match alass-cli's (80 samples per frame, 500ms minimum span) so alignment
//! behaves the same way the reference implementation does.

use std::fs::File;
use std::io::{BufReader, Read};
use webrtc_vad::{SampleRate, Vad};

/// libfvad accepts only 10, 20 or 30ms frames. At 8kHz that is 80, 160 or 240
/// samples. alass-cli uses 80, and matching it keeps span boundaries identical.
const FRAME_SAMPLES: usize = 80;
const FRAME_MS: i64 = 10;
/// alass-cli drops voice spans shorter than this before aligning.
const MIN_SPAN_MS: i64 = 500;

/// Run-length encodes per-frame voice flags into `{start_ms, end_ms}` spans,
/// dropping any span shorter than `min_span_ms`.
pub fn spans_from_flags(flags: &[bool], frame_ms: i64, min_span_ms: i64) -> Vec<(i64, i64)> {
    let mut spans = Vec::new();
    let mut start: Option<i64> = None;

    // Chaining a trailing `false` closes a span that runs to the end of input,
    // which is otherwise silently dropped.
    for (index, is_voice) in flags
        .iter()
        .copied()
        .chain(std::iter::once(false))
        .enumerate()
    {
        let index = index as i64;

        match (is_voice, start) {
            (true, None) => start = Some(index),
            (false, Some(span_start)) => {
                let (start_ms, end_ms) = (span_start * frame_ms, index * frame_ms);

                if end_ms - start_ms >= min_span_ms {
                    spans.push((start_ms, end_ms));
                }

                start = None;
            }
            _ => {}
        }
    }

    spans
}

/// Reads raw s16le mono 8kHz PCM and returns detected speech spans.
///
/// A trailing partial frame is discarded rather than zero padded, because
/// libfvad rejects any frame that is not exactly 10, 20 or 30ms.
pub fn voice_spans_from_pcm(path: &str) -> Result<Vec<(i64, i64)>, String> {
    let file = File::open(path).map_err(|e| format!("cannot open {}: {}", path, e))?;
    let mut reader = BufReader::new(file);
    let mut vad = Vad::new_with_rate(SampleRate::Rate8kHz);

    let mut raw = vec![0u8; FRAME_SAMPLES * 2];
    let mut flags = Vec::new();

    loop {
        match read_exact_or_eof(&mut reader, &mut raw)? {
            false => break,
            true => {
                let samples: Vec<i16> = raw
                    .chunks_exact(2)
                    .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                    .collect();

                let is_voice = vad
                    .is_voice_segment(&samples)
                    .map_err(|_| "vad rejected a frame".to_string())?;

                flags.push(is_voice);
            }
        }
    }

    Ok(spans_from_flags(&flags, FRAME_MS, MIN_SPAN_MS))
}

// Returns Ok(false) at a clean EOF, Ok(true) on a full frame. A partial frame
// at the end of the file counts as EOF.
fn read_exact_or_eof(reader: &mut impl Read, buf: &mut [u8]) -> Result<bool, String> {
    let mut filled = 0;

    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => return Ok(false),
            Ok(n) => filled += n,
            Err(e) => return Err(format!("read failed: {}", e)),
        }
    }

    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_a_single_run_into_one_span() {
        let flags = [false, false, true, true, true, true, true, true, false];

        assert_eq!(spans_from_flags(&flags, 10, 0), vec![(20, 80)]);
    }

    #[test]
    fn closes_a_span_that_runs_to_the_end_of_input() {
        let flags = [false, true, true, true];

        assert_eq!(spans_from_flags(&flags, 10, 0), vec![(10, 40)]);
    }

    #[test]
    fn drops_spans_shorter_than_the_minimum() {
        // A 30ms run at frames 0..2, then a 600ms run at frames 4..63. The
        // trailing `false` at frame 64 closes the second span, so it spans
        // 40ms to 640ms. Only the second survives the 500ms minimum.
        let mut flags = vec![true, true, true, false];
        flags.extend(std::iter::repeat(true).take(60));
        flags.push(false);

        assert_eq!(spans_from_flags(&flags, 10, 500), vec![(40, 640)]);
    }

    #[test]
    fn returns_nothing_for_silence() {
        assert_eq!(spans_from_flags(&[false; 100], 10, 500), Vec::new());
    }

    #[test]
    fn returns_nothing_for_empty_input() {
        assert_eq!(spans_from_flags(&[], 10, 500), Vec::new());
    }

    #[test]
    fn reports_a_missing_pcm_file_as_an_error() {
        assert!(voice_spans_from_pcm("/nonexistent/audio.pcm").is_err());
    }

    #[test]
    fn reads_silent_pcm_without_detecting_speech() {
        use std::io::Write;

        let path = std::env::temp_dir().join("mydia_subsync_silence.pcm");
        let mut file = File::create(&path).unwrap();
        // One second of digital silence: 100 frames of 80 samples.
        file.write_all(&vec![0u8; 8000 * 2]).unwrap();
        drop(file);

        let spans = voice_spans_from_pcm(path.to_str().unwrap()).unwrap();
        std::fs::remove_file(&path).unwrap();

        assert_eq!(spans, Vec::new());
    }
}
