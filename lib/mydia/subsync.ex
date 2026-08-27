defmodule Mydia.Subsync do
  @moduledoc """
  NIF bindings for automatic subtitle re-sync.

  Wraps two Rust libraries compiled into the release: `ilass` for constant
  offset alignment, and `webrtc-vad` for speech detection. Nothing here shells
  out to a binary, so there is no runtime capability check and no environment in
  which the engine is present in one place and missing in another.

  ffmpeg is still required, but that is the caller's concern: it produces the
  PCM this module reads.
  """
  use Rustler, otp_app: :mydia, crate: "mydia_subsync"

  @doc """
  Aligns a subtitle's cue spans against reference speech spans.

  Both arguments are lists of `{start_ms, end_ms}` tuples. Returns
  `{offset_ms, score}`.

  The score scales with the number of spans in `list`, so callers must normalize
  by dividing by `length(list)` before comparing against a threshold. A perfect
  match normalizes to roughly 1.0 and unrelated content to roughly 0.1.

  `list` can be empty, and this function returns a zero score for it rather
  than raising. Callers must check for that empty case before normalizing:
  `0.0 / 0` raises `ArithmeticError` in Elixir regardless of the float
  numerator, and an empty `list` is exactly the input that produces a zero
  score.

  This function never fails on unmatchable input. Given a reference it cannot
  align to, it returns its best guess with a low score, so the score is the only
  thing standing between a failed alignment and a destroyed subtitle.

  `reference` and `list` come from parsed subtitle and speech-detection data,
  which is untrusted input. The underlying `ilass` library sizes an
  internal buffer from the spread between the largest and smallest timestamp
  it is given, with no upper bound, so a single wildly out-of-range timestamp
  (well within what a two-digit-hour SRT timestamp can express) can force a
  very large allocation on the dirty scheduler thread this NIF runs on, one
  the BEAM cannot cancel once it starts. Callers must validate or clamp span
  timestamps to a sane bound derived from the media's known duration before
  calling this function.
  """
  @spec align([{integer(), integer()}], [{integer(), integer()}]) :: {integer(), float()}
  def align(_reference, _list), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Detects speech spans in raw PCM at `pcm_path`.

  The file must be signed 16-bit little-endian mono at 8000 Hz, which is what
  `ffmpeg -f s16le -ac 1 -ar 8000` produces. Returns `{:ok, spans}` where each
  span is `{start_ms, end_ms}`, or `{:error, message}` when the file cannot be
  read.

  Spans shorter than 500ms are dropped, matching alass-cli, because very short
  detections are usually noise rather than dialogue.
  """
  @spec voice_spans(String.t()) :: {:ok, [{integer(), integer()}]} | {:error, String.t()}
  def voice_spans(_pcm_path), do: :erlang.nif_error(:nif_not_loaded)
end
