defmodule Mydia.Subtitles.Resync do
  @moduledoc """
  Computes a subtitle track's timing offset by aligning it against the media
  file's own audio.

  The engine is compiled into the release as a NIF (`Mydia.Subsync`), so there
  is no binary to install and no capability check beyond ffmpeg, which produces
  the PCM the detector reads.

  Nothing here writes a subtitle file. The correction is stored as an integer
  and applied at delivery time, which makes it reversible and makes it work on
  embedded tracks that cannot be rewritten in place at all.
  """

  require Logger

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.MediaFile
  alias Mydia.Subsync
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.TrackSettings

  # Below this, a computed offset is treated as noise. Roughly the threshold of
  # perception, and moving a subtitle that was already fine is worse than
  # leaving a barely perceptible error in place.
  @min_offset_ms 150

  # Matches the range validation on subtitle_track_settings.offset_ms.
  @max_offset_ms 600_000

  # score / span_count. Measured against a real 115 minute film (see @min_cues
  # below): a correct match normalizes to 0.629 and a wrong film to 0.440, so
  # the real margin is 0.5 sitting roughly in between, not an order of
  # magnitude from either side. The crate's own synthetic tests see a much
  # wider spread, roughly 1.0 for a real match and roughly 0.1 for unrelated
  # content, which is why this threshold can look more generous than it is;
  # trust the real-media figures over the synthetic ones.
  @min_confidence 0.5

  # Measured against a real 115 minute film: a correct match normalizes to 0.629
  # and a wrong film to 0.440, but thinning the WRONG subtitle raises its score
  # past the threshold (0.502 at 107 cues, 0.652 at 14). Fewer samples must mean
  # less confidence, and the normalized score does the opposite, so cue count is
  # gated separately. See the spec calibration section; this number rests on one
  # film and wants more samples before it is trusted.
  @min_cues 200

  @doc """
  Re-syncs one subtitle track and persists the result.

  Returns `{:ok, offset_ms}` when an offset was stored, `{:skip, reason}` when
  the attempt completed but declined to store one, and `{:error, reason}` when
  it could not complete.
  """
  @spec run(MediaFile.t(), String.t()) ::
          {:ok, integer()} | {:skip, atom()} | {:error, term()}
  def run(%MediaFile{} = media_file, track_ref) do
    {result, score} = attempt(media_file, track_ref)
    record(media_file, track_ref, result, score)
    result
  end

  @doc """
  Applies the confidence and magnitude gates and returns the absolute offset.

  `residual_ms` is what alignment computed against the delivered body, and
  `existing_ms` is what is already stored for the track. Those are different
  numbers whenever an offset has been set before, because `Delivery.content/3`
  applies the stored offset on its way out. Alignment therefore measures what is
  still wrong rather than what the total correction should be, and the two are
  added here so that no caller has to remember to.

  Public so the thresholds can be tested without decoding audio. `span_count` is
  the number of subtitle cue spans, which is what the raw score scales with.
  """
  @spec decide(integer(), integer(), float(), non_neg_integer()) ::
          {:ok, integer()} | {:skip, atom()}
  def decide(_residual_ms, _existing_ms, _score, 0), do: {:skip, :no_cues}

  def decide(residual_ms, existing_ms, score, span_count) do
    absolute_ms = existing_ms + residual_ms

    cond do
      span_count < @min_cues -> {:skip, :too_few_cues}
      score / span_count < @min_confidence -> {:skip, :low_confidence}
      abs(residual_ms) < @min_offset_ms -> {:skip, :already_synced}
      abs(absolute_ms) > @max_offset_ms -> {:skip, :implausible}
      true -> {:ok, absolute_ms}
    end
  end

  @doc """
  Parses cue timings out of subtitle content into `{start_ms, end_ms}` spans.

  Only the timing lines are read. Cue text is ignored entirely, so a line of
  dialogue containing something timestamp-shaped cannot produce a phantom span.
  """
  @spec cue_spans(binary(), String.t()) :: [{integer(), integer()}]
  def cue_spans(content, format) when format in ["srt", "vtt"] do
    ~r/(\d{1,2}:)?(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,2}:)?(\d{2}):(\d{2})[,.](\d{3})/
    |> Regex.scan(content)
    |> Enum.map(fn [_full, h1, m1, s1, ms1, h2, m2, s2, ms2] ->
      {to_ms(h1, m1, s1, ms1), to_ms(h2, m2, s2, ms2)}
    end)
  end

  # `subtitle_spans/2` always requests "srt" from both `Delivery.content/3`
  # and `cue_spans/2`, so no other format ever reaches here today. No "ass"
  # clause: an untested, unreachable parser is a liability, not a feature.
  def cue_spans(_content, _format), do: []

  defp to_ms(hours, minutes, seconds, fraction) do
    hours = hours |> String.trim_trailing(":") |> parse_int()

    hours * 3_600_000 + parse_int(minutes) * 60_000 + parse_int(seconds) * 1000 +
      parse_int(fraction)
  end

  defp parse_int(""), do: 0
  defp parse_int(value), do: String.to_integer(value)

  # Returns `{result, normalized_score}`. The score rides alongside the result so
  # `run/2` can record it even for a declined attempt, which is what lets the UI
  # explain why an automatic sync did not happen.
  #
  # The whole chain runs inside one `try/after` so the PCM file is removed on
  # every exit path, not only a successful one: an ffmpeg failure still writes
  # partial output before it returns its error, and that path used to return
  # through `log_and_skip/3` without ever reaching a cleanup step. Mirrors
  # `Mydia.Library.SegmentDetection.Fingerprint.Fpcalc.fingerprint/3`, which
  # wraps its whole `with` chain, decode included, the same way.
  defp attempt(media_file, track_ref) do
    pcm_path = tmp_path(media_file, track_ref)

    try do
      with :ok <- decode_audio(media_file, pcm_path),
           {:ok, reference} <- speech_spans(pcm_path),
           {:ok, cues} <- subtitle_spans(media_file, track_ref) do
        {residual_ms, score} = Subsync.align(reference, cues)
        existing_ms = TrackSettings.offset_ms(media_file.id, track_ref)
        normalized = normalize(score, length(cues))

        case decide(residual_ms, existing_ms, score, length(cues)) do
          {:ok, absolute_ms} ->
            case TrackSettings.set_offset(media_file.id, track_ref, absolute_ms) do
              {:ok, _setting} -> {{:ok, absolute_ms}, normalized}
              {:error, changeset} -> {{:error, changeset}, normalized}
            end

          {:skip, reason} ->
            {{:skip, reason}, normalized}
        end
      else
        {:skip, reason} -> {{:skip, reason}, nil}
        {:error, reason} -> {{:error, reason}, nil}
      end
    after
      File.rm(pcm_path)
    end
  end

  defp normalize(_score, 0), do: nil
  defp normalize(score, span_count), do: score / span_count

  # Keyed on the media file, the track, and a unique integer, mirroring
  # `Fpcalc.tmp_path/0`. The media file id alone would let two tracks of the
  # same file share one path (not reachable today, since the `:subsync` queue
  # runs at concurrency 1, but the fix costs nothing and keeps the hazard from
  # depending on that queue setting staying put); the track ref is folded in
  # too so a file that does leak past the `after` above is still identifiable.
  defp tmp_path(media_file, track_ref) do
    name = "mydia_resync_#{media_file.id}_#{track_ref}_#{System.unique_integer([:positive])}.pcm"
    Path.join(System.tmp_dir!(), name)
  end

  defp decode_audio(media_file, pcm_path) do
    case MediaFile.display_path(media_file) do
      nil ->
        log_and_skip(:no_audio, media_file.id, :unresolved_path)

      path ->
        run_ffmpeg_decode(path, pcm_path)
    end
  end

  defp run_ffmpeg_decode(path, pcm_path) do
    args = [
      "-v",
      "error",
      "-y",
      "-i",
      path,
      "-vn",
      "-ac",
      "1",
      "-ar",
      "8000",
      "-f",
      "s16le",
      pcm_path
    ]

    case Ffmpeg.run(args) do
      {:ok, _output} -> :ok
      {:error, :ffmpeg_not_found} -> {:error, :ffmpeg_not_found}
      {:error, reason} -> log_and_skip(:no_audio, path, reason)
    end
  end

  defp speech_spans(pcm_path) do
    case Subsync.voice_spans(pcm_path) do
      {:ok, spans} -> {:ok, spans}
      {:error, reason} -> log_and_skip(:no_audio, pcm_path, reason)
    end
  end

  defp subtitle_spans(media_file, track_ref) do
    case Delivery.content(media_file, Delivery.track_id_from_ref(track_ref), "srt") do
      {:ok, content} ->
        case cue_spans(content, "srt") do
          [] -> {:skip, :no_cues}
          spans -> {:ok, spans}
        end

      {:error, reason} ->
        log_and_skip(:no_cues, track_ref, reason)
    end
  end

  defp log_and_skip(reason, subject, detail) do
    Logger.warning("Subtitle re-sync could not read input",
      reason: reason,
      subject: subject,
      detail: inspect(detail)
    )

    {:skip, reason}
  end

  defp record(media_file, track_ref, {:ok, _offset}, score),
    do: TrackSettings.record_resync(media_file.id, track_ref, :ok, score)

  defp record(media_file, track_ref, {:skip, reason}, score),
    do: TrackSettings.record_resync(media_file.id, track_ref, reason, score)

  defp record(media_file, track_ref, {:error, _reason}, score),
    do: TrackSettings.record_resync(media_file.id, track_ref, :failed, score)
end
