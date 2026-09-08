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

  alias Mydia.Streaming.HardwareAccel.Capabilities

  @device_glob "/dev/dri/renderD*"

  # `HardwareAccel.handle_continue(:probe, ...)` runs before any queued
  # capabilities/1, lease/2 or report_failure/3 call is answered (they queue
  # behind it in the mailbox), so a wedged vainfo or ffmpeg here blocks every
  # one of those callers until the 30s GenServer.call timeout instead of the
  # software fallback this module promises. A probe that legitimately takes
  # more than a few seconds is already broken hardware.
  @probe_timeout_ms 5_000

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
    case run_bounded("vainfo", ["--display", "drm", "--device", device]) do
      {:ok, output} ->
        matrix = parse_vainfo(output)

        if matrix.encoders == [] do
          {:error, "vainfo reported no encoders on #{device}"}
        else
          {:ok, matrix}
        end

      {:error, {:exit, _code, output}} ->
        {:error, "vainfo failed on #{device}: #{String.trim(output)}"}

      {:error, :timeout} ->
        {:error, "vainfo did not finish within #{@probe_timeout_ms}ms on #{device}"}

      {:error, :not_found} ->
        {:error, "vainfo is not installed"}
    end
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

    # Deliberately not Mydia.Library.Ffmpeg.run/2: that wraps System.cmd/3,
    # which blocks this process until the OS process exits with no way to
    # bound or interrupt it. run_bounded/3 below is the same
    # :spawn_executable + tracked-os_pid pattern FfmpegHlsTranscoder and
    # FfmpegMp4Transcoder already use to actually kill a wedged ffmpeg
    # instead of merely giving up on waiting for it.
    case run_bounded(executable(:ffmpeg_path, "ffmpeg"), args) do
      {:ok, _output} ->
        :ok

      {:error, {:exit, _code, output}} ->
        {:error, String.trim(output)}

      {:error, :timeout} ->
        {:error, "ffmpeg test encode did not finish within #{@probe_timeout_ms}ms"}

      {:error, :not_found} ->
        {:error, "ffmpeg is not installed"}
    end
  end

  # Same executable-override convention as Mydia.Library.Ffmpeg: an
  # application-env path (used by tests) falls back to resolving the bare
  # name on PATH.
  defp executable(env_key, default_name) do
    Application.get_env(:mydia, env_key) || default_name
  end

  @doc false
  # Runs `name` as a Port with a tracked OS pid, the same shape
  # FfmpegHlsTranscoder.start_ffmpeg_process/1 uses, so a timeout can
  # actually SIGKILL the child instead of merely abandoning a handle to it --
  # Task.shutdown/2 around System.cmd/3 cannot do that, since System.cmd/3
  # never gives the caller an OS pid to kill.
  #
  # Public only so the timeout and kill behaviour can be exercised directly
  # against a generic command (`sleep`, `sh`) without depending on vainfo or
  # ffmpeg being installed, and without a test having to wait out a real
  # multi-second probe; nothing outside this module should call it.
  @spec run_bounded(String.t(), [String.t()], timeout()) ::
          {:ok, binary()} | {:error, {:exit, integer(), binary()} | :timeout | :not_found}
  def run_bounded(name, args, timeout \\ @probe_timeout_ms) do
    case System.find_executable(name) do
      nil ->
        {:error, :not_found}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} -> os_pid
            nil -> nil
          end

        collect_bounded(port, os_pid, "", timeout)
    end
  end

  defp collect_bounded(port, os_pid, buffer, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_bounded(port, os_pid, buffer <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, buffer}

      {^port, {:exit_status, code}} ->
        {:error, {:exit, code, buffer}}
    after
      timeout ->
        kill_bounded(port, os_pid)
        {:error, :timeout}
    end
  end

  # Closing the port stops it relaying further messages, but does not by
  # itself terminate a running child -- Erlang's default port behaviour on
  # close is to keep the OS process alive when the driver was opened with
  # :spawn_executable. SIGKILL via the same `kill -9` mechanism the
  # transcoders use is what actually ends it, leaving no orphaned vainfo or
  # ffmpeg process behind.
  defp kill_bounded(port, os_pid) do
    if os_pid, do: System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
