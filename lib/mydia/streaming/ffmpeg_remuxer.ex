defmodule Mydia.Streaming.FfmpegRemuxer do
  @moduledoc """
  On-the-fly remuxing of video files to fragmented MP4 format.

  This module provides near-instant streaming for files where the codec is browser-compatible
  but the container isn't (e.g., MKV with H.264/AAC). Instead of transcoding, it uses FFmpeg's
  stream copy feature to remux the file to fragmented MP4 format.

  ## Benefits

  - **Near-instant startup**: No transcoding delay since we're just copying streams
  - **No buffering issues**: Stream copy is much faster than playback speed
  - **Zero quality loss**: Codec data is unchanged, only the container is different
  - **Minimal CPU usage**: Compared to HLS transcoding, remuxing uses negligible CPU

  ## FFmpeg Command

  The core FFmpeg command used for remuxing:

      ffmpeg -i input.mkv -c copy -movflags +frag_keyframe+empty_moov+default_base_moof -f mp4 pipe:1

  The `-movflags` are critical for streaming:
  - `frag_keyframe`: Create a new fragment at each keyframe (enables seeking)
  - `empty_moov`: Write the moov atom immediately with no data (enables streaming)
  - `default_base_moof`: Optimize fragment headers for seeking

  ## Usage

      # Start remuxing and get the port to read from
      {:ok, port, os_pid} = FfmpegRemuxer.start_remux("/path/to/video.mkv")

      # Stream chunks to response
      FfmpegRemuxer.stream_to_conn(conn, port)

  ## Seeking

  For seeking, we use FFmpeg's `-ss` flag:

      {:ok, port, os_pid} = FfmpegRemuxer.start_remux("/path/to/video.mkv", seek_seconds: 120)

  Note: Seeking with stream copy may be less precise than with transcoding since
  FFmpeg can only seek to keyframes when using `-c copy`.
  """

  require Logger

  alias Mydia.Streaming.AudioTrackSelector

  @type remux_opts :: [
          seek_seconds: number() | nil,
          duration: number() | nil
        ]

  @doc """
  Starts an FFmpeg process to remux a file to fragmented MP4.

  Returns `{:ok, port, os_pid}` where:
  - `port` is the Erlang port connected to FFmpeg's stdout
  - `os_pid` is the OS process ID of FFmpeg

  ## Options

  - `:seek_seconds` - (optional) Start position in seconds for seeking
  - `:duration` - (optional) Total duration in seconds. When provided, FFmpeg writes
    the correct duration to the moov atom, preventing the browser from showing
    progressively increasing duration during playback.

  ## Examples

      {:ok, port, os_pid} = FfmpegRemuxer.start_remux("/path/to/video.mkv")

      {:ok, port, os_pid} = FfmpegRemuxer.start_remux("/path/to/video.mkv", seek_seconds: 120)

      {:ok, port, os_pid} = FfmpegRemuxer.start_remux("/path/to/video.mkv", duration: 7200.5)
  """
  @spec start_remux(String.t(), remux_opts()) :: {:ok, port(), integer()} | {:error, term()}
  def start_remux(input_path, opts \\ []) do
    seek_seconds = Keyword.get(opts, :seek_seconds)

    args = build_ffmpeg_args(input_path, opts)

    Logger.info(
      "Starting fMP4 remux: #{input_path}" <>
        if(seek_seconds, do: " (seek: #{seek_seconds}s)", else: "")
    )

    Logger.debug("FFmpeg args: #{inspect(args)}")

    start_ffmpeg_process(args)
  end

  @doc """
  Streams FFmpeg output to a Plug connection using chunked transfer encoding.

  This function reads from the FFmpeg port and sends chunks directly to the client.
  It handles the connection lifecycle and cleans up the FFmpeg process on completion or error.

  ## Options

  - `:chunk_size` - Size of chunks to read from FFmpeg (default: 64KB)

  ## Returns

  Returns the connection after streaming is complete (or on error).
  """
  @spec stream_to_conn(Plug.Conn.t(), port(), integer(), Keyword.t()) :: Plug.Conn.t()
  def stream_to_conn(conn, port, os_pid, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 64 * 1024)

    # Set up chunked transfer encoding with video/mp4 content type
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("video/mp4")
      |> Plug.Conn.put_resp_header("x-streaming-mode", "remux")
      |> Plug.Conn.send_chunked(200)

    # Stream data from FFmpeg to the connection
    stream_loop(conn, port, os_pid, chunk_size)
  end

  @doc """
  Stops an FFmpeg remux process.

  Closes the port and kills the FFmpeg process if it's still running.
  """
  @spec stop_remux(port(), integer()) :: :ok
  def stop_remux(port, os_pid) do
    Logger.debug("Stopping fMP4 remux process #{os_pid}")

    # Close the port (sends SIGPIPE to FFmpeg when it tries to write)
    if Port.info(port) do
      Port.close(port)
    end

    # Give FFmpeg a moment to terminate gracefully
    Process.sleep(50)

    # Force kill if still running
    if process_alive?(os_pid) do
      Logger.debug("FFmpeg process #{os_pid} did not terminate, sending SIGKILL")
      System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  ## Private Functions

  # Build FFmpeg command arguments for fMP4 remuxing
  @doc false
  # Public only so the argument construction can be unit-tested directly,
  # matching FfmpegHlsTranscoder.build_ffmpeg_args/3; nothing outside this
  # module should call it.
  def build_ffmpeg_args(input_path, opts) do
    seek_seconds = Keyword.get(opts, :seek_seconds)
    duration = Keyword.get(opts, :duration)

    # Base args - seek first for efficiency (input seeking)
    seek_args =
      if seek_seconds && seek_seconds > 0 do
        ["-ss", to_string(seek_seconds)]
      else
        []
      end

    input_args = ["-i", input_path]

    # Which audio stream survives the remux. `-c copy` copies the codec, not
    # every stream: without an explicit -map ffmpeg still reduces to one
    # stream per type and picks the audio track with the most channels, so a
    # dual-language file silently loses its original-language track here just
    # as it does on the transcode path.
    map_args =
      opts
      |> Keyword.get(:media_file)
      |> AudioTrackSelector.select_for_playback(opts)
      |> AudioTrackSelector.ffmpeg_map_args()

    # Stream copy (no transcoding)
    codec_args = ["-c", "copy"]

    # Duration args - tell FFmpeg the total duration so it writes correct metadata
    # This prevents the browser from showing progressively increasing duration
    duration_args =
      if duration && duration > 0 do
        # Use -t to specify output duration (accounts for any seek offset)
        effective_duration =
          if seek_seconds && seek_seconds > 0 do
            max(0, duration - seek_seconds)
          else
            duration
          end

        ["-t", to_string(effective_duration)]
      else
        []
      end

    # Fragmented MP4 output flags:
    # - frag_keyframe: Create new fragment at each keyframe (enables seeking)
    # - empty_moov: Write moov atom immediately (enables streaming before file complete)
    # - default_base_moof: Optimize fragment headers
    output_args = [
      "-movflags",
      "+frag_keyframe+empty_moov+default_base_moof",
      "-f",
      "mp4",
      "-loglevel",
      "error",
      "pipe:1"
    ]

    seek_args ++ input_args ++ map_args ++ codec_args ++ duration_args ++ output_args
  end

  # Start FFmpeg process using Port
  defp start_ffmpeg_process(args) do
    ffmpeg_path = System.find_executable("ffmpeg")

    if is_nil(ffmpeg_path) do
      {:error, :ffmpeg_not_found}
    else
      try do
        port =
          Port.open(
            {:spawn_executable, ffmpeg_path},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              args: args
            ]
          )

        # Get the OS process ID
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} ->
            {:ok, port, os_pid}

          nil ->
            Port.close(port)
            {:error, :no_os_pid}
        end
      rescue
        e ->
          Logger.error("Failed to start FFmpeg process: #{inspect(e)}")
          {:error, e}
      end
    end
  end

  # Stream data from FFmpeg port to connection
  defp stream_loop(conn, port, os_pid, chunk_size) do
    receive do
      {^port, {:data, data}} ->
        # Send chunk to client
        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} ->
            stream_loop(conn, port, os_pid, chunk_size)

          {:error, :closed} ->
            # Client disconnected
            Logger.debug("Client disconnected during fMP4 streaming")
            stop_remux(port, os_pid)
            conn

          {:error, reason} ->
            # Other errors (timeout, etc.)
            Logger.warning("Chunk send failed: #{inspect(reason)}, stopping remux")
            stop_remux(port, os_pid)
            conn
        end

      {^port, {:exit_status, 0}} ->
        # FFmpeg completed successfully
        Logger.debug("fMP4 remux completed successfully")
        conn

      {^port, {:exit_status, status}} ->
        # FFmpeg exited with error
        # Status 141 = SIGPIPE (client disconnected, expected behavior)
        if status != 141 do
          Logger.warning("FFmpeg remux exited with status #{status}")
        end

        conn
    after
      # Timeout after 30 seconds of no data
      30_000 ->
        Logger.warning("fMP4 remux timeout - no data for 30 seconds")
        stop_remux(port, os_pid)
        conn
    end
  end

  # Check if an OS process is still alive
  defp process_alive?(os_pid) do
    case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
