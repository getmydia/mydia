defmodule Mydia.Subsync do
  @moduledoc """
  NIF bindings for automatic subtitle re-sync.

  Wraps two Rust libraries compiled into the release: `alass-core` for constant
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

  This function never fails on unmatchable input. Given a reference it cannot
  align to, it returns its best guess with a low score, so the score is the only
  thing standing between a failed alignment and a destroyed subtitle.
  """
  @spec align([{integer(), integer()}], [{integer(), integer()}]) :: {integer(), float()}
  def align(_reference, _list), do: :erlang.nif_error(:nif_not_loaded)
end
