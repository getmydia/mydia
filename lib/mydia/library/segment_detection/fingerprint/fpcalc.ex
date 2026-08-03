defmodule Mydia.Library.SegmentDetection.Fingerprint.Fpcalc do
  @moduledoc """
  Fingerprints audio with Chromaprint's `fpcalc`.

  ffmpeg does the decoding rather than handing the original file to `fpcalc`,
  for two reasons: ffmpeg handles every container in a real library, and it
  gives us windowing (`-ss` / `-t`) for free. `fpcalc` then reads a plain mono
  11025 Hz WAV, which is the rate Chromaprint works at internally anyway.

  The binary is resolved from PATH, or from the `:fpcalc_path` application env
  override, matching how `Mydia.Library.Ffmpeg` resolves ffmpeg.
  """

  @behaviour Mydia.Library.SegmentDetection.Fingerprint

  alias Mydia.Library.Ffmpeg
  alias Mydia.Library.SegmentDetection.Fingerprint.Result

  @sample_rate "11025"

  @impl true
  def available?, do: not is_nil(executable())

  @impl true
  def fingerprint(path, start_s, length_s) do
    tmp = tmp_path()

    try do
      with {:ok, binary} <- fpcalc_binary(),
           :ok <- decode_window(path, start_s, length_s, tmp),
           {:ok, output} <- run_fpcalc(binary, tmp, length_s),
           {:ok, %Result{} = result} <- parse_output(output) do
        {:ok, %{result | window_start_ms: max(round(start_s * 1000), 0)}}
      end
    after
      # Removed here rather than after a successful run so a crash or an error
      # return mid-fingerprint cannot leak WAVs into the temp directory.
      File.rm(tmp)
    end
  end

  @doc """
  Parses `fpcalc -raw` output into a `Result`.

  Public so it can be tested against captured output without a binary present.
  """
  @spec parse_output(String.t()) :: {:ok, Result.t()} | {:error, term()}
  def parse_output(output) when is_binary(output) do
    fields =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    with {:ok, duration_s} <- parse_duration(fields),
         {:ok, hashes} <- parse_hashes(fields) do
      # The frame rate is derived, never hardcoded: Chromaprint's frames per
      # second depends on its algorithm version, and a wrong constant produces
      # timestamps that drift further the longer the matched run. This division
      # is only correct because `-length` covers the whole input, so DURATION
      # describes the span that was actually fingerprinted. See run_fpcalc/3.
      {:ok, %Result{hashes: hashes, frame_ms: duration_s * 1000 / length(hashes)}}
    end
  end

  defp parse_duration(%{"DURATION" => raw}) do
    case Float.parse(raw) do
      {seconds, _rest} when seconds > 0 -> {:ok, seconds}
      _ -> {:error, :no_duration}
    end
  end

  defp parse_duration(_fields), do: {:error, :no_duration}

  defp parse_hashes(%{"FINGERPRINT" => raw}) do
    hashes =
      raw
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn value ->
        case Integer.parse(String.trim(value)) do
          # fpcalc may print signed values; mask back to unsigned 32-bit so the
          # correlator's bit arithmetic behaves.
          {int, _rest} -> [Bitwise.band(int, 0xFFFFFFFF)]
          :error -> []
        end
      end)

    if hashes == [], do: {:error, :no_fingerprint}, else: {:ok, hashes}
  end

  defp parse_hashes(_fields), do: {:error, :no_fingerprint}

  defp decode_window(path, start_s, length_s, tmp) do
    args = [
      "-nostdin",
      "-ss",
      to_string(start_s),
      "-t",
      to_string(length_s),
      "-i",
      path,
      "-vn",
      "-ac",
      "1",
      "-ar",
      @sample_rate,
      "-f",
      "wav",
      "-y",
      tmp
    ]

    case Ffmpeg.run(args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # `-length` is mandatory, do not remove it as redundant.
  #
  # fpcalc defaults to fingerprinting only the first 120 seconds of its input
  # and silently discarding the rest. Two things break when that happens:
  # the detection window is truncated to two minutes, so an intro after a cold
  # open is never seen; and DURATION still reports the length of the whole
  # input rather than the fingerprinted span, so the derived frame_ms comes back
  # roughly 5x too large (measured 614.98 ms/frame against a true 124.17). Every
  # episode pair went from matching to not matching. Passing a length that
  # covers the whole temp WAV keeps DURATION and the frame count describing the
  # same span. One extra second absorbs ffmpeg rounding at the window edge.
  defp run_fpcalc(binary, tmp, length_s) do
    args = ["-raw", "-length", to_string(ceil(length_s) + 1), tmp]

    case System.cmd(binary, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:fpcalc_error, code, output}}
    end
  end

  defp fpcalc_binary do
    case executable() do
      nil -> {:error, :fpcalc_not_found}
      binary -> {:ok, binary}
    end
  end

  # An application-env override is resolved the same way as a bare name, so a
  # stale or non-executable override surfaces as :fpcalc_not_found instead of
  # raising inside System.cmd/3.
  defp executable do
    System.find_executable(Application.get_env(:mydia, :fpcalc_path) || "fpcalc")
  end

  defp tmp_path do
    name = "mydia_fp_#{System.unique_integer([:positive])}.wav"
    Path.join(System.tmp_dir!(), name)
  end
end
