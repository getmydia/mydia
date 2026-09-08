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
  alias Mydia.Streaming.HardwareAccel
  alias Mydia.Streaming.HardwareAccel.Args, as: AccelArgs

  @type transcode_opts :: [
          input_path: String.t(),
          output_dir: String.t(),
          on_progress: (map() -> any()) | nil,
          on_complete: (-> any()) | nil,
          on_error: (String.t() -> any()) | nil,
          on_hwaccel_failed: (String.t() -> any()) | nil,
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
      :on_segments,
      :on_hwaccel_failed,
      :playlist_path,
      :buffer,
      :duration,
      :started_at,
      ready_notified: false,
      seen_segments: MapSet.new(),
      accel_tier: :software,
      output_buffer: ""
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
            on_segments: ([non_neg_integer()] -> any()) | nil,
            on_hwaccel_failed: (String.t() -> any()) | nil,
            seen_segments: MapSet.t(non_neg_integer()),
            playlist_path: String.t() | nil,
            buffer: String.t(),
            duration: float() | nil,
            started_at: DateTime.t(),
            ready_notified: boolean(),
            accel_tier: AccelArgs.tier(),
            output_buffer: String.t()
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
    * `:on_hwaccel_failed` - (optional) Callback called with the buffered FFmpeg
      output when a hardware initialisation failure is detected. The process
      then stops with reason `:normal` (recoverable, not a crash) instead of
      `{:ffmpeg_exit, status}`; the callback is the only way the caller learns
      why.
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

  @doc """
  The segment indices FFmpeg's own playlist lists as finished.

  The playlist is the authoritative completion signal: FFmpeg appends an entry
  only once a segment is closed. Reading the directory instead would race with
  a segment still being written.

  Public so the parsing can be unit-tested without running FFmpeg.
  """
  @spec finished_indices(String.t()) :: [non_neg_integer()]
  def finished_indices(playlist_text) do
    playlist_text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn line ->
      case Mydia.Streaming.SegmentPlan.index_from_name(line) do
        {:ok, index} -> [index]
        :error -> []
      end
    end)
    |> Enum.sort()
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
    on_segments = Keyword.get(opts, :on_segments)
    on_hwaccel_failed = Keyword.get(opts, :on_hwaccel_failed)

    # Build FFmpeg command
    args = build_ffmpeg_args(input_path, output_dir, opts)

    # Derived from the argument list rather than by calling AccelArgs.build/2
    # again: re-deriving from inputs risks drift, and build_ffmpeg_args/3's
    # return shape can't change without breaking the six regression test
    # files that assert its exact output. The gate below only needs to know
    # whether this was a hardware attempt at all, but deriving the precise
    # tier costs nothing and keeps the log line below accurate.
    accel_tier =
      cond do
        "-hwaccel" in args -> :full_hardware
        "-init_hw_device" in args -> :hybrid
        true -> :software
      end

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
          on_segments: on_segments,
          on_hwaccel_failed: on_hwaccel_failed,
          playlist_path: playlist_path,
          buffer: "",
          duration: nil,
          started_at: DateTime.utc_now(),
          accel_tier: accel_tier,
          output_buffer: ""
        }

        # One timer drives both signals. Readiness is just "the playlist
        # exists"; the segment poll is "which entries has it grown".
        if on_ready || on_segments do
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

    # Separate, bounded accumulation of raw stderr so the hwaccel classifier
    # sees the whole message rather than one chunk — `buffer` above gets
    # cleared as soon as parse_ffmpeg_output/1 recognizes a line, which would
    # otherwise chop a multi-line VAAPI failure apart before it could match.
    state = %{state | output_buffer: append_output(state.output_buffer, data)}

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

    # The poll loop runs on a fixed cadence that has nothing to do with when
    # FFmpeg actually writes its last segment and exits, so a tail segment
    # finished in the gap since the last poll would otherwise never be
    # reported. One last read before the process (and this GenServer) is
    # gone.
    state = final_segment_catchup(state)

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
    # Same tail-segment gap as the zero-exit clause above: an encoder that
    # dies mid-window can still have finished segments sitting in the
    # playlist that no poll ever reported.
    state = final_segment_catchup(state)

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

    if state.accel_tier != :software and hwaccel_failure?(state.output_buffer) do
      Logger.warning(
        "Hardware encode failed to initialise (tier #{state.accel_tier}); " <>
          "the session will retry in software"
      )

      if state.on_hwaccel_failed do
        state.on_hwaccel_failed.(state.output_buffer)
      end

      # :normal, not {:hwaccel_failed, output}: HlsSession links to this
      # process (see the comment on HlsSession.relocate/2), and a link to a
      # non-trapping process only kills it for a non-normal exit. A hardware
      # init failure is recoverable and must not take the session down the
      # same way a genuine crash does; on_hwaccel_failed above is what tells
      # the session to actually recover it.
      {:stop, :normal, state}
    else
      {:stop, {:ffmpeg_exit, status}, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("FFmpeg process terminated: #{inspect(reason)}")
    {:stop, {:ffmpeg_terminated, reason}, state}
  end

  def handle_info(:check_playlist_ready, state) do
    state = final_segment_catchup(state)

    # Readiness fires once; segment discovery runs for the life of the encoder.
    if state.on_segments || !state.ready_notified do
      Process.send_after(self(), :check_playlist_ready, 250)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in FfmpegHlsTranscoder: #{inspect(msg)}")
    {:noreply, state}
  end

  # One last playlist read before the GenServer stops. The regular poll
  # loop runs on a fixed timer that has no relationship to when FFmpeg
  # actually finishes its last segment and exits, so without this call a
  # tail segment finished in the gap between the last poll and process exit
  # is never reported through on_segments. A caller downstream
  # (TranscodeWindow.decide/2) then waits on a segment nothing will ever
  # produce.
  #
  # Public only so the catch-up read can be exercised directly in tests
  # without needing a real FFmpeg process to exit at a controlled moment;
  # nothing outside this module should call it.
  @doc false
  @spec final_segment_catchup(State.t()) :: State.t()
  def final_segment_catchup(state) do
    case File.read(state.playlist_path) do
      {:ok, contents} -> handle_playlist(state, contents)
      {:error, _reason} -> state
    end
  end

  # Notifies readiness the first time the playlist appears, and reports any
  # segment indices that have shown up since the previous poll.
  defp handle_playlist(state, contents) do
    state =
      if state.ready_notified do
        state
      else
        Logger.debug("Playlist file detected: #{state.playlist_path}")
        if state.on_ready, do: state.on_ready.()
        %{state | ready_notified: true}
      end

    if state.on_segments do
      fresh =
        contents
        |> finished_indices()
        |> Enum.reject(&MapSet.member?(state.seen_segments, &1))

      if fresh == [] do
        state
      else
        state.on_segments.(fresh)
        %{state | seen_segments: Enum.into(fresh, state.seen_segments)}
      end
    else
      state
    end
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

  @doc """
  Whether the video stream will be re-encoded rather than copied.

  This is the single place that decision gets made; `build_ffmpeg_args/3`
  calls it too, so the two can never disagree. Only a re-encode can have its
  keyframes forced onto the segment grid, so this is also what decides
  whether `grid_aligned` may be set: `HlsSession` calls it before starting or
  relocating the encoder, to decide what to pass as `grid_aligned`.
  """
  @spec reencodes_video?(Mydia.Library.MediaFile.t() | nil, integer() | nil) :: boolean()
  def reencodes_video?(media_file, max_bitrate) do
    transcode_policy =
      Application.get_env(:mydia, :streaming, [])
      |> Keyword.get(:transcode_policy, :copy_when_compatible)

    cond do
      not is_nil(max_bitrate) -> true
      transcode_policy != :copy_when_compatible -> true
      is_nil(media_file) -> true
      true -> not should_copy_video?(media_file.codec)
    end
  end

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

    # Determine video codec - use copy if compatible and policy allows, otherwise
    # transcode. An explicit opt always wins; short of that, reencodes_video?/2
    # is the single decider, so this can never disagree with what HlsSession
    # used to decide `grid_aligned`.
    video_codec =
      case Keyword.get(opts, :video_codec) do
        nil when force_transcode ->
          Logger.info("Bitrate cap set (#{max_bitrate}kbps), forcing video transcode to H.264")
          "libx264"

        nil ->
          if reencodes_video?(media_file, max_bitrate) do
            Logger.info(
              "Video codec #{(media_file && media_file.codec) || "unknown"} needs transcoding to H.264"
            )

            "libx264"
          else
            Logger.info(
              "Video codec #{media_file.codec} is compatible, using stream copy (fast, no quality loss)"
            )

            "copy"
          end

        explicit ->
          explicit
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
    segment_pattern = Path.join(output_dir, "segment_%05d.ts")
    start_number = Keyword.get(opts, :start_number, 0)
    segment_seconds = Mydia.Streaming.SegmentPlan.default_segment_seconds()

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

    # Acceleration is decided only on the encode branch. A stream copy returns
    # empty argument lists, so nothing here can turn a copy into a transcode.
    accel =
      if video_codec == "copy" do
        %AccelArgs{tier: :software, input: [], video: []}
      else
        capabilities =
          Keyword.get_lazy(opts, :capabilities, fn -> HardwareAccel.capabilities() end)

        video_bitrate_kbps =
          if max_bitrate do
            kbps = max(max_bitrate - @audio_bitrate_kbps, 100)
            Logger.info("Using ABR mode: video=#{kbps}kbps, total_cap=#{max_bitrate}kbps")
            kbps
          end

        AccelArgs.build(capabilities,
          source_codec: media_file && media_file.codec,
          max_height: max_height,
          video_bitrate_kbps: video_bitrate_kbps,
          crf: crf,
          preset: preset,
          video_codec: video_codec
        )
      end

    Logger.info("Encoding tier: #{accel.tier}")

    # -hwaccel flags must precede -i. After it, ffmpeg has already selected a
    # decoder and silently ignores them.
    base_args = seek_args ++ accel.input ++ ["-i", input_path]

    video_args =
      if video_codec == "copy" do
        ["-c:v", "copy"]
      else
        accel.video
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

    # The playlist FFmpeg writes here is internal bookkeeping only: it is how
    # HlsSession learns which segments are finished. What the player receives is
    # SegmentPlan.playlist/1, computed from the media duration before FFmpeg
    # starts. -hls_list_size 0 keeps every entry so the session can read the
    # whole set on each poll.
    #
    # -start_number makes filenames absolute, so a window relocated to t=400s
    # writes segment_00100.ts, which is the name the published playlist already
    # promised. -hls_flags temp_file makes FFmpeg write to a temporary name and
    # rename on completion. Without it a half-written segment exists on disk
    # and the session would hand the player a truncated file. Both are
    # harmless in either mode, so unlike the timestamp flags below they are
    # never gated.
    hls_args = [
      "-f",
      "hls",
      "-hls_time",
      to_string(segment_seconds),
      "-hls_list_size",
      "0",
      "-start_number",
      to_string(start_number),
      "-hls_flags",
      "temp_file",
      "-hls_segment_filename",
      segment_pattern,
      "-progress",
      "pipe:1",
      "-loglevel",
      "info",
      playlist_path
    ]

    # -copyts keeps source timestamps, so a relocated segment reports its real
    # media time rather than restarting near zero.
    #
    # -muxdelay 0 -muxpreload 0 are not optional decoration. The TS muxer's
    # defaults add a reproducible 1.4s to every window's timestamps, the
    # un-relocated first one included, which would put every segment that far
    # from the time the published playlist declares for it. Zeroing both brings
    # the error down to about 20ms. Measured, not assumed: without them segment
    # 100 lands at 401.378667s, with them at 399.978667s.
    #
    # -output_ts_offset is deliberately absent. On top of -copyts it would apply
    # the seek offset a second time.
    #
    # Gated on absolute_timestamps (true only for a :full session, whose fixed
    # segment grid needs a relocated encoder to report real media time). A
    # :window session never relocates and must keep reporting near-zero
    # timestamps after a resume seek: the player's StreamTimeline
    # (player/lib/core/player/stream_timeline.dart) exists to map that
    # near-zero playback position back onto the real one by adding its resume
    # offset, and absolute timestamps here would make it double that offset.
    # HlsSession passes absolute_timestamps: playlist_mode == :full.
    timestamp_args =
      if Keyword.get(opts, :absolute_timestamps, false) do
        ["-copyts", "-muxdelay", "0", "-muxpreload", "0"]
      else
        []
      end

    # Only meaningful when the video stream is re-encoded. On a copied stream
    # the keyframes are whatever the source has, and FFmpeg rejects the flag
    # outright. reencodes_video?/2 above is what decides whether grid_aligned
    # may be true; HlsSession calls it before starting or relocating the
    # encoder and passes the answer straight through as this opt.
    keyframe_args =
      if Keyword.get(opts, :grid_aligned, false) do
        ["-force_key_frames", "expr:gte(t,n_forced*#{segment_seconds})"]
      else
        []
      end

    # Combine all args. The maps sit directly after the input and before the
    # codec flags, which is where ffmpeg expects output stream selection.
    base_args ++
      AudioTrackSelector.ffmpeg_map_args(selected_audio) ++
      video_args ++ audio_args ++ keyframe_args ++ timestamp_args ++ hls_args
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

  # Matched against ffmpeg's stderr to tell a hardware initialisation failure
  # from an ordinary encode error. Only the former is worth retrying in
  # software: retrying a genuine error would hide a bug behind a second, slower
  # failure. The first pattern is captured verbatim from a container whose
  # ffmpeg links libva with no driver installed.
  #
  # Deliberately NOT included: a standalone `Function not implemented`
  # pattern. That string is the literal strerror(ENOSYS) text ffmpeg prints
  # via av_strerror for ANY AVERROR(ENOSYS) — an unsupported muxer, protocol,
  # or codec feature, not only hardware device init. Matching it on its own
  # would classify an unrelated encode-time ENOSYS as a hardware failure and
  # retry it in software, which is exactly the over-matching this classifier
  # exists to avoid. The real VAAPI case is still caught: it always appears
  # as the parenthetical on the connection line, which
  # `Failed to initialise VAAPI connection` already matches.
  @hwaccel_failure_patterns [
    ~r/Failed to initialise VAAPI connection/i,
    ~r/No VA display found/i,
    ~r/Device creation failed/i,
    ~r/Failed to open .*\/dev\/dri\/.*Permission denied/i,
    ~r/for option 'init_hw_device'/i,
    ~r/for option 'hwaccel_device'/i
  ]

  @doc """
  Whether ffmpeg's output describes a hardware initialisation failure.

  Public so the classifier can be tested against captured output without
  starting a transcoder.
  """
  @spec hwaccel_failure?(String.t()) :: boolean()
  def hwaccel_failure?(output) when is_binary(output) do
    Enum.any?(@hwaccel_failure_patterns, &Regex.match?(&1, output))
  end

  def hwaccel_failure?(_), do: false

  # Bound in bytes, not graphemes. String.slice/3 counts grapheme clusters,
  # so slicing a buffer full of multi-byte characters to "the last 4,000"
  # keeps 4,000 *graphemes* — up to 3x @output_buffer_bytes for 3-byte UTF-8
  # sequences (common CJK/accented text, realistic here since this is a
  # self-hosted media server with arbitrary international file paths). This
  # buffer lives for the whole session, so that growth is exactly what the
  # bound exists to prevent.
  @output_buffer_bytes 4_000

  @doc false
  # Public only so the byte bound can be unit-tested directly, without
  # starting a transcoder; nothing outside this module should call it.
  def append_output(buffer, data) do
    combined = buffer <> data
    size = byte_size(combined)

    if size > @output_buffer_bytes do
      # A byte-based cut can land inside a multi-byte character, leaving
      # invalid UTF-8 at the start of the buffer. That's fine here: the
      # buffer is only ever regex-matched, and @hwaccel_failure_patterns are
      # plain ASCII without the `u` modifier, so the regex engine matches
      # against raw bytes and never raises on the malformed prefix.
      # Scrubbing it back to valid UTF-8 would cost more than it buys.
      binary_part(combined, size - @output_buffer_bytes, @output_buffer_bytes)
    else
      combined
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
