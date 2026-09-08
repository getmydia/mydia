defmodule Mydia.Downloads.FfmpegMp4Transcoder do
  @moduledoc """
  FFmpeg-based progressive MP4 transcoding for downloads.

  This module transcodes video files to progressive-playable fragmented MP4 format
  (fMP4) for optimized downloads. Unlike HLS segments, this produces a single MP4
  file that can be played before the download completes.

  ## Key Features

  - **Progressive playback**: File is playable before transcoding completes (thanks to `empty_moov`)
  - **Single file output**: Unlike HLS, produces one MP4 file instead of segments
  - **Resolution presets**: 1080p, 720p, and 480p with sensible encoding defaults
  - **Progress reporting**: Real-time progress callbacks during transcoding
  - **Cleanup on error**: Properly stops FFmpeg and cleans up on errors or cancellation

  ## FFmpeg Command Structure

  The core FFmpeg command used (software tier shown; a VAAPI-capable host
  swaps in `h264_vaapi` and a `scale_vaapi` filter instead):

      ffmpeg -i input.mkv \
        -c:v libx264 -preset medium -crf 23 \
        -pix_fmt yuv420p -profile:v high \
        -vf scale=-2:1080 \
        -c:a aac -b:a 128k -ar 48000 -ac 2 \
        -movflags +frag_keyframe+empty_moov+default_base_moof \
        -progress pipe:2 \
        -f mp4 output.mp4

  The `-movflags` are critical for progressive playback:
  - `frag_keyframe`: Create a new fragment at each keyframe (enables seeking)
  - `empty_moov`: Write the moov atom immediately (enables playback before complete)
  - `default_base_moof`: Optimize fragment headers for seeking

  ## Hardware Acceleration

  The video encode goes through `Mydia.Streaming.HardwareAccel.Args`, the same
  builder the HLS path uses, so a VAAPI-capable host encodes with `h264_vaapi`
  instead of `libx264`. This is a background job rather than interactive
  playback, so `init/1` takes a `:background` lease from
  `Mydia.Streaming.HardwareAccel`, which is refused one slot early so an
  interactive playback start never waits behind a batch download; a refusal
  just means "encode in software". If the hardware encoder fails to
  initialise, the whole job restarts once in software (there is no window or
  segment grid to preserve here, unlike HLS) via `retry_in_software?/1` and
  `Mydia.Streaming.FfmpegHlsTranscoder.hwaccel_failure?/1`.

  ## Usage

      {:ok, pid} = FfmpegMp4Transcoder.start_transcoding(
        input_path: "/path/to/video.mkv",
        output_path: "/path/to/output.mp4",
        resolution: :p720,
        on_progress: fn progress -> IO.inspect(progress) end,
        on_complete: fn -> IO.puts("Done!") end,
        on_error: fn error -> IO.puts("Error: \#{error}") end
      )

      # Stop transcoding
      FfmpegMp4Transcoder.stop_transcoding(pid)
  """

  use GenServer
  require Logger

  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HardwareAccel
  alias Mydia.Streaming.HardwareAccel.Args, as: AccelArgs
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @type resolution :: :p1080 | :p720 | :p480
  @type transcode_opts :: [
          input_path: String.t(),
          output_path: String.t(),
          resolution: resolution(),
          on_progress: (map() -> any()) | nil,
          on_complete: (-> any()) | nil,
          on_error: (String.t() -> any()) | nil,
          preset: String.t(),
          crf: integer()
        ]

  defmodule State do
    @moduledoc false
    defstruct [
      :input_path,
      :output_path,
      :resolution,
      :ffmpeg_pid,
      :ffmpeg_port,
      :on_progress,
      :on_complete,
      :on_error,
      :buffer,
      :duration,
      :started_at,
      :job_id,
      :source_codec,
      :opts,
      :hwaccel_lease,
      hwaccel_retried: false,
      output_buffer: ""
    ]

    @type t :: %__MODULE__{
            input_path: String.t(),
            output_path: String.t(),
            resolution: FfmpegMp4Transcoder.resolution(),
            ffmpeg_pid: integer() | nil,
            ffmpeg_port: port() | nil,
            on_progress: (map() -> any()) | nil,
            on_complete: (-> any()) | nil,
            on_error: (String.t() -> any()) | nil,
            buffer: String.t(),
            duration: float() | nil,
            started_at: DateTime.t(),
            job_id: String.t() | nil,
            source_codec: String.t() | nil,
            opts: keyword(),
            hwaccel_lease: reference() | nil,
            hwaccel_retried: boolean(),
            output_buffer: String.t()
          }
  end

  # Resolution presets with sensible dimensions
  @resolution_presets %{
    p1080: %{width: 1920, height: 1080},
    p720: %{width: 1280, height: 720},
    p480: %{width: 854, height: 480}
  }

  ## Client API

  @doc """
  Starts a new FFmpeg transcoding process for progressive MP4.

  ## Options

    * `:input_path` - (required) Path to the input video file
    * `:output_path` - (required) Path where the output MP4 file will be written
    * `:resolution` - (optional) Resolution preset (`:p1080`, `:p720`, `:p480`, default: `:p720`)
    * `:on_progress` - (optional) Callback function called with progress updates
    * `:on_complete` - (optional) Callback function called when transcoding completes
    * `:on_error` - (optional) Callback function called when an error occurs
    * `:preset` - (optional) FFmpeg preset for encoding speed/quality (default: "medium")
    * `:crf` - (optional) Constant Rate Factor for quality (default: 23)

  ## Progress Callbacks

  The `on_progress` callback receives a map with:
    - `:time` - Current transcoding position in seconds
    - `:percentage` - Progress percentage (0-100) if duration is known

  ## Examples

      {:ok, pid} = FfmpegMp4Transcoder.start_transcoding(
        input_path: "/path/to/video.mkv",
        output_path: "/tmp/output.mp4",
        resolution: :p720,
        on_progress: fn %{percentage: pct} -> IO.puts("Progress: \#{pct}%") end,
        on_complete: fn -> IO.puts("Transcoding complete!") end,
        on_error: fn error -> IO.puts("Error: \#{error}") end
      )
  """
  @spec start_transcoding(transcode_opts()) :: GenServer.on_start()
  def start_transcoding(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops an active transcoding process.

  Gracefully terminates the FFmpeg process and cleans up the output file.
  """
  @spec stop_transcoding(pid()) :: :ok
  def stop_transcoding(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Gets the current transcoding status.
  """
  @spec get_status(pid()) :: {:ok, map()} | {:error, term()}
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    input_path = Keyword.fetch!(opts, :input_path)
    output_path = Keyword.fetch!(opts, :output_path)
    resolution = Keyword.get(opts, :resolution, :p720)

    # Validate resolution preset
    if Map.has_key?(@resolution_presets, resolution) do
      # Ensure output directory exists
      output_dir = Path.dirname(output_path)
      File.mkdir_p!(output_dir)

      # Extract callbacks
      on_progress = Keyword.get(opts, :on_progress)
      on_complete = Keyword.get(opts, :on_complete)
      on_error = Keyword.get(opts, :on_error)

      # A background lease is refused one slot early so an interactive
      # playback start never waits behind a batch download transcode. A
      # refusal means "encode in software", not an error -- fall back to the
      # software capabilities so build_ffmpeg_args/4 never reaches for a
      # device this job was refused.
      {capabilities, lease} =
        case HardwareAccel.lease(:background) do
          {:ok, ref} -> {HardwareAccel.capabilities(), ref}
          :refused -> {Capabilities.software("no hardware slot free for a background job"), nil}
        end

      opts = Keyword.put(opts, :capabilities, capabilities)

      # Build FFmpeg command
      args = build_ffmpeg_args(input_path, output_path, resolution, opts)

      Logger.info("Starting FFmpeg MP4 transcoding: #{input_path} -> #{output_path}")
      Logger.debug("FFmpeg args: #{inspect(args)}")

      # Start FFmpeg process
      case start_ffmpeg_process(args) do
        {:ok, port, pid} ->
          state = %State{
            input_path: input_path,
            output_path: output_path,
            resolution: resolution,
            ffmpeg_pid: pid,
            ffmpeg_port: port,
            on_progress: on_progress,
            on_complete: on_complete,
            on_error: on_error,
            buffer: "",
            duration: nil,
            started_at: DateTime.utc_now(),
            job_id: Keyword.get(opts, :media_file_id, input_path),
            source_codec: Keyword.get(opts, :source_codec),
            opts: opts,
            hwaccel_lease: lease,
            hwaccel_retried: false,
            output_buffer: ""
          }

          {:ok, state}

        {:error, reason} ->
          Logger.error("Failed to start FFmpeg process: #{inspect(reason)}")
          if lease, do: HardwareAccel.release(lease)
          {:stop, {:ffmpeg_start_failed, reason}}
      end
    else
      Logger.error("Invalid resolution preset: #{resolution}")
      {:stop, {:invalid_resolution, resolution}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      input_path: state.input_path,
      output_path: state.output_path,
      resolution: state.resolution,
      ffmpeg_alive?: is_port(state.ffmpeg_port) and Port.info(state.ffmpeg_port) != nil,
      duration: state.duration,
      started_at: state.started_at
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{ffmpeg_port: port} = state) when is_port(port) do
    # FFmpeg progress is written to stderr (which we redirect to stdout)
    # Log raw FFmpeg output for debugging
    if String.trim(data) != "" do
      Logger.debug("FFmpeg: #{String.trim(data)}")
    end

    # Accumulate output in buffer
    buffer = state.buffer <> data

    # Separate, bounded accumulation of raw stderr so the hwaccel classifier
    # sees the whole message rather than one chunk -- `buffer` above gets
    # cleared as soon as parse_ffmpeg_output/1 recognizes a line, which would
    # otherwise chop a multi-line VAAPI failure apart before it could match.
    state = %{state | output_buffer: FfmpegHlsTranscoder.append_output(state.output_buffer, data)}

    # Parse FFmpeg output for progress and duration
    state =
      buffer
      |> parse_ffmpeg_output()
      |> case do
        {:duration, duration} ->
          Logger.debug("Detected video duration: #{duration}s")
          %{state | duration: duration, buffer: ""}

        {:progress, progress_data} ->
          if state.on_progress && state.duration do
            percentage = progress_data.time / state.duration * 100
            progress = Map.put(progress_data, :percentage, percentage)
            state.on_progress.(progress)
          end

          %{state | buffer: ""}

        {:error, error_msg} ->
          Logger.error("FFmpeg error: #{error_msg}")

          if state.on_error do
            state.on_error.(error_msg)
          end

          %{state | buffer: ""}

        :no_match ->
          # Keep buffer for next iteration (but limit size)
          buffer = if byte_size(buffer) > 10_000, do: "", else: buffer
          %{state | buffer: buffer}
      end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, 0}}, %{ffmpeg_port: port} = state) do
    Logger.info("FFmpeg MP4 transcoding completed successfully")

    if state.on_complete do
      state.on_complete.()
    end

    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, status}}, %{ffmpeg_port: port} = state) do
    # Include any buffered output in the error message
    error_details =
      if state.buffer != "" do
        "\nFFmpeg output:\n#{state.buffer}"
      else
        ""
      end

    error_msg = "FFmpeg exited with status #{status}#{error_details}"
    Logger.error(error_msg)

    if state.on_error do
      state.on_error.(error_msg)
    end

    if retry_in_software?(state) do
      Logger.warning(
        "Download transcode hardware encode failed; restarting in software for job " <>
          "#{state.job_id}"
      )

      HardwareAccel.report_failure(:vaapi, state.source_codec)

      case restart_in_software(state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, reason} ->
          Logger.error("Failed to restart FFmpeg in software: #{inspect(reason)}")
          {:stop, {:ffmpeg_failed, status}, state}
      end
    else
      # {:ffmpeg_failed, status}, not {:ffmpeg_exit, status}: JobManager
      # pattern-matches on this exact reason (see
      # lib/mydia/downloads/job_manager.ex) to drive download job failure
      # handling, unlike the HLS transcoder's equivalent reason which nothing
      # matches on.
      {:stop, {:ffmpeg_failed, status}, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("FFmpeg process terminated: #{inspect(reason)}")
    {:stop, {:ffmpeg_terminated, reason}, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in FfmpegMp4Transcoder: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating FFmpeg MP4 transcoder, reason: #{inspect(reason)}")

    # Release the hardware slot on every exit path -- normal completion,
    # ffmpeg failure, or a crash -- so a leaked background lease never starves
    # playback of a slot it was never using.
    if state.hwaccel_lease, do: HardwareAccel.release(state.hwaccel_lease)

    # Stop FFmpeg process if still running
    if is_port(state.ffmpeg_port) && Port.info(state.ffmpeg_port) do
      # Get OS PID before closing port
      os_pid = state.ffmpeg_pid

      # Close the port (sends SIGTERM to FFmpeg)
      Port.close(state.ffmpeg_port)

      # Give FFmpeg a moment to gracefully shutdown
      Process.sleep(100)

      # Verify the process has terminated, force kill if needed
      if os_pid && process_alive?(os_pid) do
        Logger.warning("FFmpeg process #{os_pid} did not terminate gracefully, sending SIGKILL")

        System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      else
        Logger.debug("FFmpeg process #{os_pid} terminated successfully")
      end
    end

    # Clean up partial output file on error (not on normal termination)
    if reason != :normal && File.exists?(state.output_path) do
      Logger.debug("Cleaning up partial output file: #{state.output_path}")
      File.rm(state.output_path)
    end

    :ok
  end

  ## Private Functions

  # Check if an OS process is still alive
  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # Build FFmpeg command arguments for progressive MP4 transcoding.
  #
  # `-s WxH` is deliberately gone: it forces exact dimensions with no aspect
  # handling and cannot coexist with a hardware filter chain -- it would force
  # a software scale after the frames are already on the GPU. The height
  # reaches AccelArgs as :max_height instead, so one filter expression
  # (software scale, or scale_vaapi on the hardware tiers) handles every
  # resolution preset.
  @doc false
  # Public only so the argument construction can be unit-tested directly,
  # without spawning ffmpeg; nothing outside this module should call it.
  def build_ffmpeg_args(input_path, output_path, resolution, opts) do
    %{height: height} = @resolution_presets[resolution]

    capabilities =
      Keyword.get_lazy(opts, :capabilities, fn ->
        HardwareAccel.capabilities()
      end)

    accel =
      AccelArgs.build(capabilities,
        source_codec: Keyword.get(opts, :source_codec),
        max_height: height,
        crf: Keyword.get(opts, :crf, 23),
        preset: Keyword.get(opts, :preset, "medium")
      )

    # -hwaccel flags must precede -i. After it, ffmpeg has already selected a
    # decoder and silently ignores them.
    accel.input ++
      ["-i", input_path] ++
      accel.video ++
      [
        # Audio encoding
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-ar",
        "48000",
        "-ac",
        "2",
        # Fragmented MP4 output flags for progressive playback -- these are
        # what make the file playable before the download completes; losing
        # them breaks progressive playback silently, with no error.
        # - frag_keyframe: Create new fragment at each keyframe (enables seeking)
        # - empty_moov: Write moov atom immediately (enables playback before complete)
        # - default_base_moof: Optimize fragment headers
        "-movflags",
        "+frag_keyframe+empty_moov+default_base_moof",
        # Progress reporting (FFmpeg writes to stderr)
        "-progress",
        "pipe:2",
        # Format and output
        "-f",
        "mp4",
        output_path
      ]
  end

  # Whether a non-zero ffmpeg exit should be retried once in software.
  #
  # Public so the branch decision is testable without spawning ffmpeg,
  # mirroring FfmpegHlsTranscoder.hwaccel_failure?/1. A hardware failure is
  # only worth retrying the first time -- retrying a genuine encode error
  # would just hide a bug behind a second, slower failure -- so a job that
  # already retried always answers false here regardless of what the output
  # looks like.
  @doc false
  @spec retry_in_software?(map()) :: boolean()
  def retry_in_software?(%{hwaccel_retried: true}), do: false

  def retry_in_software?(%{output_buffer: output}) do
    FfmpegHlsTranscoder.hwaccel_failure?(output)
  end

  # Restarts the whole job in software after a hardware initialisation
  # failure. There is no window or segment grid to preserve here, unlike the
  # HLS session, so this rebuilds the arguments from scratch and spawns a
  # fresh port rather than relocating anything.
  defp restart_in_software(state) do
    if state.hwaccel_lease, do: HardwareAccel.release(state.hwaccel_lease)

    opts =
      Keyword.put(
        state.opts,
        :capabilities,
        Capabilities.software("fell back after a hardware failure")
      )

    args = build_ffmpeg_args(state.input_path, state.output_path, state.resolution, opts)

    Logger.debug("FFmpeg args (software fallback): #{inspect(args)}")

    case start_ffmpeg_process(args) do
      {:ok, port, pid} ->
        {:ok,
         %{
           state
           | ffmpeg_pid: pid,
             ffmpeg_port: port,
             buffer: "",
             output_buffer: "",
             opts: opts,
             hwaccel_lease: nil,
             hwaccel_retried: true
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Start FFmpeg process using Port
  defp start_ffmpeg_process(args) do
    try do
      port =
        Port.open(
          {:spawn_executable, System.find_executable("ffmpeg")},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ]
        )

      # Get the OS process ID
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} ->
          {:ok, port, os_pid}

        nil ->
          {:error, :no_os_pid}
      end
    rescue
      e ->
        {:error, e}
    end
  end

  # Parse FFmpeg output for duration, progress, and errors
  defp parse_ffmpeg_output(output) do
    cond do
      # Duration: 00:01:23.45
      output =~ ~r/Duration: (\d{2}):(\d{2}):(\d{2}\.\d{2})/ ->
        [_, hours, minutes, seconds] =
          Regex.run(~r/Duration: (\d{2}):(\d{2}):(\d{2}\.\d{2})/, output)

        duration =
          String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60 +
            String.to_float(seconds)

        {:duration, duration}

      # out_time_ms=12345678 (FFmpeg progress format)
      output =~ ~r/out_time_ms=(\d+)/ ->
        [_, time_ms] = Regex.run(~r/out_time_ms=(\d+)/, output)
        time_seconds = String.to_integer(time_ms) / 1_000_000

        progress = %{
          time: time_seconds
        }

        {:progress, progress}

      # Error detection
      output =~ ~r/Error|Invalid|failed/i ->
        {:error, String.trim(output)}

      true ->
        :no_match
    end
  end
end
