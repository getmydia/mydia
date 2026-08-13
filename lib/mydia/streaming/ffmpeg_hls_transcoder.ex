defmodule Mydia.Streaming.FfmpegHlsTranscoder do
  @moduledoc """
  FFmpeg-based HLS transcoding backend.

  This module uses FFmpeg directly to transcode video files to HLS format,
  supporting virtually all codecs and container formats.

  ## Features

  - **Universal codec support**: Works with any format FFmpeg supports (H264, HEVC, VP9, AAC, EAC3, DTS, AC3, etc.)
  - **Production-ready**: FFmpeg is battle-tested and widely used
  - **Simple implementation**: Single command with clear error messages
  - **Efficient**: Supports stream copy for compatible codecs (10-100x faster)

  ## Usage

      {:ok, pid} = FfmpegHlsTranscoder.start_transcoding(
        input_path: "/path/to/video.mkv",
        output_dir: "/tmp/hls-session-123",
        on_progress: fn progress -> IO.inspect(progress) end,
        on_complete: fn -> IO.puts("Done!") end,
        on_error: fn error -> IO.puts("Error: \#{error}") end
      )

      # Stop transcoding
      FfmpegHlsTranscoder.stop_transcoding(pid)

  ## Process Management

  The transcoder runs as a GenServer that spawns and monitors an FFmpeg process.
  It tracks the process state and can report progress by parsing FFmpeg output.
  """

  use GenServer
  require Logger

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.AudioTrackSelector

  @type transcode_opts :: [
          input_path: String.t(),
          output_dir: String.t(),
          on_progress: (map() -> any()) | nil,
          on_complete: (-> any()) | nil,
          on_error: (String.t() -> any()) | nil,
          media_file: Mydia.Library.MediaFile.t() | nil,
          video_codec: String.t(),
          audio_codec: String.t(),
          preset: String.t(),
          crf: integer(),
          max_bitrate: integer() | nil,
          max_height: integer() | nil
        ]

  defmodule State do
    @moduledoc false
    defstruct [
      :input_path,
      :output_dir,
      :ffmpeg_pid,
      :ffmpeg_port,
      :on_progress,
      :on_complete,
      :on_error,
      :on_ready,
      :playlist_path,
      :buffer,
      :duration,
      :started_at,
      ready_notified: false
    ]

    @type t :: %__MODULE__{
            input_path: String.t(),
            output_dir: String.t(),
            ffmpeg_pid: pid() | nil,
            ffmpeg_port: port() | nil,
            on_progress: (map() -> any()) | nil,
            on_complete: (-> any()) | nil,
            on_error: (String.t() -> any()) | nil,
            on_ready: (-> any()) | nil,
            playlist_path: String.t() | nil,
            buffer: String.t(),
            duration: float() | nil,
            started_at: DateTime.t(),
            ready_notified: boolean()
          }
  end

  ## Client API

  @doc """
  Starts a new FFmpeg transcoding process.

  ## Options

    * `:input_path` - (required) Path to the input video file
    * `:output_dir` - (required) Directory where HLS segments and playlists will be written
    * `:media_file` - (optional) MediaFile struct for intelligent codec detection
    * `:on_progress` - (optional) Callback function called with progress updates
    * `:on_complete` - (optional) Callback function called when transcoding completes
    * `:on_error` - (optional) Callback function called when an error occurs
    * `:video_codec` - (optional) Video codec (default: auto-detect from media_file or "libx264")
    * `:audio_codec` - (optional) Audio codec (default: auto-detect from media_file or "aac")
    * `:preset` - (optional) FFmpeg preset (default: "medium")
    * `:crf` - (optional) Constant Rate Factor for quality (default: 23)
    * `:max_bitrate` - (optional) Total kbps cap; forces a transcode when set
    * `:max_height` - (optional) Output height ceiling in pixels. Preserves
      aspect ratio and never upscales. Omitted means native resolution.

  ## Stream Copy Optimization

  When a `media_file` is provided, the transcoder will intelligently decide whether to
  copy or transcode each stream based on browser compatibility:

    - H.264 video → copy (10-100x faster, zero quality loss)
    - AAC audio → copy (10-100x faster, zero quality loss)
    - Incompatible codecs → transcode to H.264/AAC

  ## Examples

      # With media_file for intelligent optimization
      {:ok, pid} = FfmpegHlsTranscoder.start_transcoding(
        input_path: "/path/to/video.mkv",
        output_dir: "/tmp/hls",
        media_file: media_file
      )

      # Manual codec control
      {:ok, pid} = FfmpegHlsTranscoder.start_transcoding(
        input_path: "/path/to/video.mkv",
        output_dir: "/tmp/hls",
        video_codec: "copy",
        audio_codec: "aac"
      )
  """
  @spec start_transcoding(transcode_opts()) :: GenServer.on_start()
  def start_transcoding(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops an active transcoding process.
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
    output_dir = Keyword.fetch!(opts, :output_dir)

    # Ensure output directory exists
    File.mkdir_p!(output_dir)

    # Extract callbacks
    on_progress = Keyword.get(opts, :on_progress)
    on_complete = Keyword.get(opts, :on_complete)
    on_error = Keyword.get(opts, :on_error)
    on_ready = Keyword.get(opts, :on_ready)

    # Build FFmpeg command
    args = build_ffmpeg_args(input_path, output_dir, opts)

    Logger.info("Starting FFmpeg HLS transcoding: #{input_path}")
    Logger.debug("FFmpeg args: #{inspect(args)}")

    # Calculate playlist path for ready detection
    playlist_path = Path.join(output_dir, "index.m3u8")

    # Start FFmpeg process
    case start_ffmpeg_process(args) do
      {:ok, port, pid} ->
        state = %State{
          input_path: input_path,
          output_dir: output_dir,
          ffmpeg_pid: pid,
          ffmpeg_port: port,
          on_progress: on_progress,
          on_complete: on_complete,
          on_error: on_error,
          on_ready: on_ready,
          playlist_path: playlist_path,
          buffer: "",
          duration: nil,
          started_at: DateTime.utc_now()
        }

        # Schedule first playlist check if we have an on_ready callback
        if on_ready do
          Process.send_after(self(), :check_playlist_ready, 100)
        end

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start FFmpeg process: #{inspect(reason)}")
        {:stop, {:ffmpeg_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      input_path: state.input_path,
      output_dir: state.output_dir,
      ffmpeg_alive?: is_port(state.ffmpeg_port) and Port.info(state.ffmpeg_port) != nil,
      duration: state.duration,
      started_at: state.started_at
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{ffmpeg_port: port} = state) when is_port(port) do
    # Log raw FFmpeg output for debugging (helpful when diagnosing issues)
    if String.trim(data) != "" do
      Logger.debug("FFmpeg: #{String.trim(data)}")
    end

    # Accumulate output in buffer
    buffer = state.buffer <> data

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
    Logger.info("FFmpeg transcoding completed successfully")

    # Notify readiness if not already done — when FFmpeg completes very quickly
    # (e.g., stream copy), the scheduled :check_playlist_ready may not have fired yet.
    if !state.ready_notified && state.on_ready && File.exists?(state.playlist_path) do
      Logger.info("FFmpeg completed before readiness check — notifying ready now")
      state.on_ready.()
    end

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

    {:stop, {:ffmpeg_failed, status}, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("FFmpeg process terminated: #{inspect(reason)}")
    {:stop, {:ffmpeg_terminated, reason}, state}
  end

  def handle_info(:check_playlist_ready, %{ready_notified: true} = state) do
    # Already notified, stop checking
    {:noreply, state}
  end

  def handle_info(:check_playlist_ready, state) do
    if File.exists?(state.playlist_path) do
      Logger.debug("Playlist file detected: #{state.playlist_path}")

      # Call the on_ready callback
      if state.on_ready do
        state.on_ready.()
      end

      {:noreply, %{state | ready_notified: true}}
    else
      # Not ready yet, check again in 100ms
      Process.send_after(self(), :check_playlist_ready, 100)
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in FfmpegHlsTranscoder: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating FFmpeg transcoder, reason: #{inspect(reason)}")

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

  # Determines if a video codec is compatible with browsers and can be copied instead of re-encoded
  defp should_copy_video?(nil), do: false

  defp should_copy_video?(codec) when is_binary(codec) do
    normalized = String.downcase(codec)

    # H.264 (AVC) is universally supported by browsers
    normalized in ["h264", "avc", "avc1"]
  end

  # Determines if an audio codec is compatible with browsers and can be copied instead of re-encoded
  defp should_copy_audio?(nil), do: false

  defp should_copy_audio?(codec) when is_binary(codec) do
    normalized = String.downcase(codec)

    # AAC is universally supported by browsers
    normalized in ["aac", "mp4a"]
  end

  # Audio bitrate budget (kbps) subtracted from total when calculating video bitrate
  @audio_bitrate_kbps 128

  # Build FFmpeg command arguments for HLS transcoding
  @doc false
  # Public only so the argument construction can be unit-tested directly;
  # nothing outside this module should call it.
  def build_ffmpeg_args(input_path, output_dir, opts) do
    media_file = Keyword.get(opts, :media_file)
    max_bitrate = Keyword.get(opts, :max_bitrate)
    max_height = effective_max_height(Keyword.get(opts, :max_height))

    # Get transcode policy from config
    transcode_policy =
      Application.get_env(:mydia, :streaming, [])
      |> Keyword.get(:transcode_policy, :copy_when_compatible)

    # When max_bitrate is set, force transcoding (no video stream copy)
    # since we need to control the output bitrate
    force_transcode = not is_nil(max_bitrate)

    # Determine video codec - use copy if compatible and policy allows, otherwise transcode
    video_codec =
      cond do
        Keyword.get(opts, :video_codec) ->
          Keyword.get(opts, :video_codec)

        force_transcode ->
          Logger.info("Bitrate cap set (#{max_bitrate}kbps), forcing video transcode to H.264")
          "libx264"

        not is_nil(media_file) and transcode_policy == :copy_when_compatible ->
          if should_copy_video?(media_file.codec) do
            Logger.info(
              "Video codec #{media_file.codec} is compatible, using stream copy (fast, no quality loss)"
            )

            "copy"
          else
            Logger.info("Video codec #{media_file.codec || "unknown"} needs transcoding to H.264")
            "libx264"
          end

        true ->
          if transcode_policy == :always do
            Logger.debug("Transcode policy is :always, transcoding video to H.264")
          end

          "libx264"
      end

    # Which audio stream this playback carries, resolved before the codec
    # decision because that decision has to be about the stream actually being
    # mapped. `media_file.audio_codec` describes the *first* audio stream
    # (see Mydia.Library.FileAnalyzer), so on a file whose first track is
    # stereo AAC and whose second is 5.1 DTS, deciding "aac, so copy" from the
    # first and then mapping the second puts a DTS stream in an HLS segment no
    # browser can decode. Silent audio, no error.
    selected_audio = AudioTrackSelector.select_for_playback(media_file, opts)

    audio_source_codec =
      case selected_audio do
        %StreamInfo{codec: codec} when is_binary(codec) -> codec
        _ -> media_file && media_file.audio_codec
      end

    # Determine audio codec - use copy if compatible and policy allows, otherwise transcode
    audio_codec =
      case Keyword.get(opts, :audio_codec) do
        nil when not is_nil(media_file) and transcode_policy == :copy_when_compatible ->
          if should_copy_audio?(audio_source_codec) do
            Logger.info(
              "Audio codec #{audio_source_codec} is compatible, using stream copy (fast, no quality loss)"
            )

            "copy"
          else
            Logger.info("Audio codec #{audio_source_codec || "unknown"} needs transcoding to AAC")

            "aac"
          end

        nil ->
          if transcode_policy == :always do
            Logger.debug("Transcode policy is :always, transcoding audio to AAC")
          end

          "aac"

        codec ->
          codec
      end

    preset = Keyword.get(opts, :preset, "medium")
    crf = Keyword.get(opts, :crf, 23)

    # Use index.m3u8 to match HLS controller expectations
    playlist_path = Path.join(output_dir, "index.m3u8")
    segment_pattern = Path.join(output_dir, "segment_%03d.ts")

    # `-ss` before `-i` is input seeking: FFmpeg jumps to the nearest keyframe
    # without decoding everything before it. Placed after `-i` it would decode
    # and discard the whole preceding hour, which is unusable for resume.
    #
    # The consequence is that playlist timestamps start at ~0 rather than at the
    # offset, which is why the client has to carry a StreamTimeline to map
    # stream-local positions back onto real media positions.
    seek_args =
      case Keyword.get(opts, :start_position, 0) do
        pos when is_integer(pos) and pos > 0 -> ["-ss", to_string(pos)]
        _ -> []
      end

    base_args =
      seek_args ++
        [
          "-i",
          input_path
        ]

    # Build video encoding args
    video_args =
      if video_codec == "copy" do
        # Stream copy - no encoding parameters needed
        ["-c:v", "copy"]
      else
        # Base encoding parameters shared by CRF and ABR modes
        base_video = [
          "-c:v",
          video_codec,
          "-preset",
          preset,
          "-pix_fmt",
          "yuv420p",
          "-profile:v",
          "high",
          "-g",
          "60",
          "-bf",
          "0"
        ]

        # Rate control: ABR when max_bitrate is set, CRF otherwise
        rate_control =
          if max_bitrate do
            video_kbps = max(max_bitrate - @audio_bitrate_kbps, 100)

            Logger.info("Using ABR mode: video=#{video_kbps}kbps, total_cap=#{max_bitrate}kbps")

            [
              "-b:v",
              "#{video_kbps}k",
              "-maxrate",
              "#{video_kbps}k",
              "-bufsize",
              "#{video_kbps * 2}k"
            ]
          else
            ["-crf", to_string(crf)]
          end

        base_video ++ scale_args(max_height) ++ rate_control
      end

    # Build audio encoding args
    audio_args =
      if audio_codec == "copy" do
        # Stream copy - no encoding parameters needed
        ["-c:a", "copy"]
      else
        # Full transcoding with encoding parameters
        [
          "-c:a",
          audio_codec,
          "-b:a",
          "#{@audio_bitrate_kbps}k",
          "-ar",
          "48000",
          "-ac",
          "2"
        ]
      end

    # HLS output parameters
    # Use live-style playlist (no -hls_playlist_type) so playlist updates incrementally
    # as segments are written. This allows playback to start quickly without waiting
    # for the entire file to be processed.
    # -hls_list_size 0 keeps all segments in playlist for full seeking capability
    hls_args = [
      "-f",
      "hls",
      "-hls_time",
      "4",
      "-hls_list_size",
      "0",
      "-hls_segment_filename",
      segment_pattern,
      # Progress reporting
      "-progress",
      "pipe:1",
      "-loglevel",
      "info",
      playlist_path
    ]

    # Combine all args. The maps sit directly after the input and before the
    # codec flags, which is where ffmpeg expects output stream selection.
    base_args ++
      AudioTrackSelector.ffmpeg_map_args(selected_audio) ++
      video_args ++ audio_args ++ hls_args
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

      # out_time_ms=12345678
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

  # Builds the video scale filter. Every encode gets one; only the ceiling is
  # optional.
  #
  # `-2` keeps the width proportional to the source and divisible by two,
  # which H.264 requires; hardcoding both dimensions (the previous `-s
  # WxH`) distorted anything that was not 16:9. `min(h, ih)` clamps against
  # the *input* height so a rung above the source never upscales, which
  # would burn CPU to produce a larger, blurrier picture.
  #
  # The comma inside `min()` is backslash-escaped because FFmpeg reads a
  # bare comma in a filtergraph as a filter separator. The usual shell form
  # `-vf scale=-2:'min(720,ih)'` is wrong here: these arguments go straight
  # to a port with no shell, so the quotes would arrive literally and the
  # filter would fail to parse.
  #
  # `2*trunc(.../2)` rounds the height down to an even number, and it is the
  # reason the uncapped clause emits a filter at all rather than nothing. An
  # odd frame height makes libx264 with `-pix_fmt yuv420p` refuse to open the
  # encoder outright ("height not divisible by 2", exit 187): the transcode
  # dies before writing a playlist, the client's playlist wait times out, and
  # the viewer gets a generic playback error with nothing in it pointing here.
  #
  # That is reachable on the DEFAULT path, not just under a cap. The old
  # hardcoded `-s 1280x720` evened every transcode as a side effect; removing
  # it (correctly, since it also squished everything that was not 16:9) took
  # the evening with it. VP9 and AV1 both permit odd frame heights and are
  # exactly the codecs this module force-transcodes, and ordinary rips like
  # 720x405 and 848x477 are odd too. Rounding down rather than up is what
  # keeps the no-upscale guarantee; `-2` then tracks the width to it, which is
  # what preserves the aspect ratio.
  #
  # Only ever reached on the encode branch — a stream copy returns before
  # this, so no filter can turn a copy into a transcode.
  defp scale_args(height) when is_integer(height) and height > 0 do
    ["-vf", "scale=-2:2*trunc(min(#{height}\\,ih)/2)"]
  end

  # A zero or negative ceiling would scale to nothing. It can only arrive from
  # a misconfigured `streaming.max_transcode_height` (the schema rejects it,
  # but a stale cached runtime config could still carry one), so say so rather
  # than silently ignoring it and leaving the operator to wonder why their cap
  # does nothing. The encode still gets the evening filter: a bad ceiling is
  # no reason to hand libx264 an odd height.
  defp scale_args(height) when is_integer(height) do
    Logger.warning(
      "Ignoring a non-positive transcode height ceiling (#{height}); " <>
        "encoding at the source resolution"
    )

    even_height_args()
  end

  defp scale_args(_), do: even_height_args()

  # No ceiling: keep the source resolution, rounded down to an even height.
  defp even_height_args, do: ["-vf", "scale=-2:2*trunc(ih/2)"]

  @doc """
  Composes a requested output height with the operator's configured ceiling
  by taking whichever is lower.

  Either may be nil, meaning "no limit from this source"; nil from both means
  native resolution.

  Public because the GraphQL resolver echoes back the height it actually
  applied, and that echo has to be derived from the same expression the
  filter is. Computing it separately meant an operator who set
  `streaming.max_transcode_height` made the server tell a direct-connection
  client "Original" while this module really did scale.

  The ceiling comes from the layered runtime config (env > DB/UI > YAML >
  schema defaults; see `Mydia.Config.Loader`) rather than a flat
  `Application.get_env(:mydia, :streaming, ...)` key. Nothing explodes the
  resolved config struct back out to flat keys, so a flat read here would
  silently ignore both `MAX_TRANSCODE_HEIGHT` and the settings UI.
  """
  @spec effective_max_height(integer() | nil) :: integer() | nil
  def effective_max_height(requested) do
    case {requested, configured_max_height()} do
      {nil, nil} -> nil
      {nil, cap} -> cap
      {height, nil} -> height
      {height, cap} -> min(height, cap)
    end
  end

  defp configured_max_height do
    case Mydia.Config.get() do
      %{streaming: %{max_transcode_height: height}} -> height
      _ -> nil
    end
  end
end
