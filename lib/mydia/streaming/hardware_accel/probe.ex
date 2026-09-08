defmodule Mydia.Streaming.HardwareAccel.Probe do
  @moduledoc """
  Detects what the host's video hardware can do.

  Three steps, in order, because each rules out a different false positive:

  1. Enumerate `/dev/dri/renderD*`. No node means no device.
  2. Parse `vainfo` for the profile and entrypoint matrix. This is what fills
     the decode and encode lists without synthesizing a test clip per codec.
  3. Run one real throwaway encode.

  Step 3 is not redundant. `ffmpeg -hwaccels` lists `vaapi` whenever the API was
  compiled in, and the stock Alpine image ships `libva.so.2` with no driver in
  `/usr/lib/dri`, so ffmpeg advertises VAAPI and then fails at `vaInitialize`.
  Steps 1 and 2 alone would reproduce exactly that false positive.
  """

  require Logger

  alias Mydia.Library.Ffmpeg
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @device_glob "/dev/dri/renderD*"

  # VAProfile names map onto codec atoms. Profile variants (Main, Main10,
  # High, Profile0) collapse onto the codec, because the tier decision only
  # asks "can this device decode av1 at all".
  @profile_patterns [
    {~r/VAProfileH264/, :h264},
    {~r/VAProfileHEVC/, :hevc},
    {~r/VAProfileAV1/, :av1},
    {~r/VAProfileVP9/, :vp9},
    {~r/VAProfileVP8/, :vp8},
    {~r/VAProfileMPEG2/, :mpeg2video},
    {~r/VAProfileVC1/, :vc1}
  ]

  @spec run(keyword()) :: Capabilities.t()
  def run(opts \\ []) do
    case Keyword.get(opts, :hwaccel, :auto) do
      :off ->
        Capabilities.software("disabled by HWACCEL=off")

      :invalid ->
        Capabilities.software("HWACCEL is set to an unrecognised value")

      backend when backend in [:auto, :vaapi] ->
        probe_devices(backend, opts)
    end
  end

  defp probe_devices(backend, opts) do
    case candidate_devices(opts) do
      [] ->
        Capabilities.software(no_device_reason(opts))

      devices ->
        devices
        |> Enum.reduce_while({:error, []}, fn device, {:error, failures} ->
          case probe_device(device) do
            {:ok, caps} -> {:halt, {:ok, forced_note(caps, backend)}}
            {:error, reason} -> {:cont, {:error, [{device, reason} | failures]}}
          end
        end)
        |> case do
          {:ok, caps} ->
            caps

          {:error, failures} ->
            reason = failure_reason(Enum.reverse(failures))
            Logger.warning("No usable VAAPI device: #{reason}")
            Capabilities.software(reason)
        end
    end
  end

  defp candidate_devices(opts) do
    case Keyword.get(opts, :device) do
      nil -> Path.wildcard(Keyword.get(opts, :device_glob, @device_glob))
      device -> if File.exists?(device), do: [device], else: []
    end
  end

  defp no_device_reason(opts) do
    case Keyword.get(opts, :device) do
      nil -> "no render node present under /dev/dri"
      device -> "requested device #{device} does not exist"
    end
  end

  # Each device's actual failure text is preserved. Discarding it and reporting
  # a generic "no usable device" collapses "the driver package is missing" into
  # the same bucket as "vainfo is not installed" and "the test encode failed",
  # and those lead an operator to three different actions. The driver-missing
  # case is the one measured on real hardware, so it is exactly the one that
  # must survive.
  defp failure_reason(failures) do
    Enum.map_join(failures, "; ", fn {device, reason} -> "#{device}: #{reason}" end)
  end

  # An explicitly requested backend is recorded in the reason so the settings
  # page can say the operator asked for it, which matters once Spec B adds a
  # second backend and `auto` could have chosen differently.
  defp forced_note(caps, :auto), do: caps
  defp forced_note(caps, backend), do: %{caps | reason: "selected by HWACCEL=#{backend}"}

  defp probe_device(device) do
    with {:ok, matrix} <- vainfo(device),
         :ok <- test_encode(device) do
      {:ok,
       %Capabilities{
         backend: :vaapi,
         device: device,
         encoders: matrix.encoders,
         decode_profiles: matrix.decode_profiles
       }}
    end
  end

  defp vainfo(device) do
    case System.cmd("vainfo", ["--display", "drm", "--device", device], stderr_to_stdout: true) do
      {output, 0} ->
        matrix = parse_vainfo(output)

        if matrix.encoders == [] do
          {:error, "vainfo reported no encoders on #{device}"}
        else
          {:ok, matrix}
        end

      {output, _code} ->
        {:error, "vainfo failed on #{device}: #{String.trim(output)}"}
    end
  rescue
    ErlangError -> {:error, "vainfo is not installed"}
  end

  @doc """
  Extracts the codec matrix from `vainfo` output.

  `VAEntrypointVLD` is decode. `VAEntrypointEncSlice` and `VAEntrypointEncSliceLP`
  are encode. Reading VLD as encode support would select an encoder the device
  does not have: this hardware decodes AV1 and cannot encode it.
  """
  @spec parse_vainfo(String.t()) :: %{encoders: [atom()], decode_profiles: [atom()]}
  def parse_vainfo(output) do
    lines = String.split(output, "\n")

    %{
      decode_profiles: codecs_for(lines, ~r/VAEntrypointVLD\s*$/),
      encoders: codecs_for(lines, ~r/VAEntrypointEncSlice(LP)?\s*$/)
    }
  end

  defp codecs_for(lines, entrypoint) do
    lines
    |> Enum.filter(&Regex.match?(entrypoint, &1))
    |> Enum.flat_map(fn line ->
      Enum.filter(@profile_patterns, fn {pattern, _codec} -> Regex.match?(pattern, line) end)
    end)
    |> Enum.map(fn {_pattern, codec} -> codec end)
    |> Enum.uniq()
  end

  # The definitive check. Encodes two seconds of generated video through the
  # hybrid path, which exercises device creation, the filter device and the
  # encoder in one go.
  defp test_encode(device) do
    args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-init_hw_device",
      "vaapi=hw:#{device}",
      "-filter_hw_device",
      "hw",
      "-f",
      "lavfi",
      "-i",
      "testsrc=size=320x240:duration=1:rate=15",
      "-vf",
      "format=nv12,hwupload",
      "-c:v",
      "h264_vaapi",
      "-f",
      "null",
      "-"
    ]

    case Ffmpeg.run(args) do
      {:ok, _output} -> :ok
      {:error, {:ffmpeg_error, _code, output}} -> {:error, String.trim(output)}
      {:error, :ffmpeg_not_found} -> {:error, "ffmpeg is not installed"}
    end
  end
end
