defmodule Mydia.Streaming.HlsSession do
  @moduledoc """
  GenServer managing individual HLS transcoding sessions.

  Each session represents a single user streaming a specific media file.
  The session starts a transcoding backend (FFmpeg or Membrane) to transcode
  the file on-demand, manages temporary storage for HLS segments, and
  automatically terminates after a period of inactivity.

  ## Backends

  Two transcoding backends are supported:

  - **FFmpeg** (default): Universal codec support, production-ready, simpler implementation
  - **Membrane**: Experimental, limited codec support, more granular control

  The backend is configured via application config:

      config :mydia, :streaming, hls_backend: :ffmpeg

  ## Lifecycle

  1. Session started with media_file_id
  2. Creates unique session directory in /tmp
  3. Starts transcoding backend (FFmpeg or Membrane)
  4. Tracks activity via heartbeat messages
  5. Auto-terminates after 10 minutes of inactivity
  6. Cleans up temp files on termination

  ## Usage

      # Start a session
      {:ok, pid} = HlsSession.start_link(media_file_id: 123)

      # Get session info (triggers heartbeat)
      {:ok, info} = HlsSession.get_info(pid)

      # Stop session manually
      HlsSession.stop(pid)
  """

  use GenServer
  require Logger

  alias Mydia.Library
  alias Mydia.Streaming.{HlsPipeline, FfmpegHlsTranscoder}

  # Get session timeout and temp dir from config or use defaults
  # Default timeout is 10 minutes - sessions are kept alive via heartbeats during active playback
  @session_timeout Application.compile_env(
                     :mydia,
                     [:streaming, :session_timeout],
                     :timer.minutes(10)
                   )
  @temp_base_dir Application.compile_env(:mydia, [:streaming, :temp_base_dir], "/tmp/mydia-hls")

  defmodule State do
    @moduledoc false
    defstruct [
      :session_id,
      :media_file,
      :media_file_id,
      :user_id,
      :backend,
      :backend_pid,
      :temp_dir,
      :last_activity,
      :timeout_ref,
      :playlist_path
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            media_file: Mydia.Library.MediaFile.t(),
            media_file_id: integer(),
            user_id: integer(),
            backend: :ffmpeg | :membrane,
            backend_pid: pid() | nil,
            temp_dir: String.t(),
            last_activity: DateTime.t(),
            timeout_ref: reference() | nil,
            playlist_path: String.t() | nil
          }
  end

  ## Client API

  @doc """
  Starts an HLS transcoding session for a media file.

  ## Options

    * `:media_file_id` - (required) ID of the media file to transcode
    * `:user_id` - (required) ID of the user requesting the stream
    * `:registry_key` - (required) Registry key for session registration
    * `:name` - (optional) GenServer name for registration

  ## Examples

      {:ok, pid} = HlsSession.start_link(media_file_id: 123, user_id: 456, registry_key: {:hls_session, 123, 456})
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Gets session information including session ID, temp directory, and activity status.

  This also serves as a heartbeat, updating the last_activity timestamp.
  """
  def get_info(pid) do
    GenServer.call(pid, :get_info)
  end

  @doc """
  Records activity on the session, resetting the inactivity timer.
  """
  def heartbeat(pid) do
    GenServer.cast(pid, :heartbeat)
  end

  @doc """
  Caches the playlist file path for faster subsequent lookups.
  """
  def cache_playlist_path(pid, path) do
    GenServer.cast(pid, {:cache_playlist_path, path})
  end

  @doc """
  Gets the cached playlist path if available.
  """
  def get_playlist_path(pid) do
    GenServer.call(pid, :get_playlist_path)
  end

  @doc """
  Gracefully stops the session, cleaning up resources.
  """
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    media_file_id = Keyword.fetch!(opts, :media_file_id)
    user_id = Keyword.fetch!(opts, :user_id)
    registry_key = Keyword.fetch!(opts, :registry_key)

    # Load media file with metadata
    try do
      media_file = Library.get_media_file!(media_file_id, preload: [:media_item, :episode])

      # Register this session in the Registry
      Registry.register(
        Mydia.Streaming.HlsSessionRegistry,
        registry_key,
        %{
          media_file_id: media_file_id,
          user_id: user_id,
          started_at: DateTime.utc_now()
        }
      )

      # Generate session ID and create temp directory
      session_id = generate_session_id()
      temp_dir = Path.join(@temp_base_dir, session_id)

      # Register session by session_id for O(1) lookup
      Registry.register(
        Mydia.Streaming.HlsSessionRegistry,
        {:session, session_id},
        %{
          media_file_id: media_file_id,
          user_id: user_id,
          temp_dir: temp_dir
        }
      )

      case File.mkdir_p(temp_dir) do
        :ok ->
          Logger.info(
            "Starting HLS session #{session_id} for media file #{media_file_id}, user #{user_id}"
          )

          Logger.info("Temp directory: #{temp_dir}")

          # Get backend from config (default to :ffmpeg)
          backend =
            Application.get_env(:mydia, :streaming, [])
            |> Keyword.get(:hls_backend, :ffmpeg)

          Logger.info("Starting HLS transcoding with backend: #{backend}")

          # Start the appropriate backend
          case start_backend(backend, media_file, temp_dir) do
            {:ok, backend_pid} ->
              # Link to backend process so we terminate if it crashes
              Process.link(backend_pid)

              state = %State{
                session_id: session_id,
                media_file: media_file,
                media_file_id: media_file_id,
                user_id: user_id,
                backend: backend,
                backend_pid: backend_pid,
                temp_dir: temp_dir,
                last_activity: DateTime.utc_now()
              }

              # Schedule initial timeout check
              state = schedule_timeout_check(state)

              {:ok, state}

            {:error, reason} ->
              Logger.error(
                "Failed to start #{backend} backend for session #{session_id}: #{inspect(reason)}"
              )

              File.rm_rf!(temp_dir)
              {:stop, {:backend_start_failed, reason}}
          end

        {:error, reason} ->
          Logger.error("Failed to create temp directory #{temp_dir}: #{inspect(reason)}")
          {:stop, {:temp_dir_creation_failed, reason}}
      end
    rescue
      Ecto.NoResultsError ->
        Logger.error("Media file #{media_file_id} not found")
        {:stop, :media_file_not_found}
    end
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    # Getting info counts as activity
    state = update_activity(state)

    info = %{
      session_id: state.session_id,
      media_file_id: state.media_file_id,
      backend: state.backend,
      temp_dir: state.temp_dir,
      last_activity: state.last_activity,
      backend_alive?: is_pid(state.backend_pid) and Process.alive?(state.backend_pid)
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:get_playlist_path, _from, state) do
    {:reply, {:ok, state.playlist_path}, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    state = update_activity(state)
    {:noreply, state}
  end

  def handle_cast({:cache_playlist_path, path}, state) do
    {:noreply, %{state | playlist_path: path}}
  end

  @impl true
  def handle_info(:check_timeout, state) do
    now = DateTime.utc_now()
    inactive_duration = DateTime.diff(now, state.last_activity, :millisecond)

    if inactive_duration >= @session_timeout do
      Logger.info("Session #{state.session_id} inactive for #{inactive_duration}ms, terminating")

      {:stop, :timeout, state}
    else
      # Still active, schedule next check
      state = schedule_timeout_check(state)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{backend_pid: pid} = state) do
    Logger.warning("Backend #{state.backend} (#{inspect(pid)}) terminated: #{inspect(reason)}")
    # Backend died, we should terminate too
    {:stop, {:backend_terminated, reason}, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in HlsSession: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating HLS session #{state.session_id}, reason: #{inspect(reason)}")

    # Stop the backend if it's still running
    if state.backend_pid && Process.alive?(state.backend_pid) do
      stop_backend(state.backend, state.backend_pid)
    end

    # Clean up temp directory
    case File.rm_rf(state.temp_dir) do
      {:ok, _files} ->
        Logger.info("Cleaned up temp directory: #{state.temp_dir}")

      {:error, reason, _file} ->
        Logger.warning("Failed to clean up temp directory #{state.temp_dir}: #{inspect(reason)}")
    end

    :ok
  end

  ## Private Functions

  # Start the appropriate backend based on configuration
  defp start_backend(:ffmpeg, media_file, temp_dir) do
    Logger.info("Starting FFmpeg backend for #{media_file.path}")

    case FfmpegHlsTranscoder.start_transcoding(
           input_path: media_file.path,
           output_dir: temp_dir,
           media_file: media_file,
           on_complete: fn ->
             Logger.info("FFmpeg transcoding completed for #{media_file.path}")
           end,
           on_error: fn error ->
             Logger.error("FFmpeg transcoding error for #{media_file.path}: #{error}")
           end
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_backend(:membrane, media_file, temp_dir) do
    Logger.info("Starting Membrane backend for #{media_file.path}")

    pipeline_opts = [
      source_path: media_file.path,
      output_dir: temp_dir,
      media_file: media_file
    ]

    case Membrane.Pipeline.start_link(HlsPipeline, pipeline_opts) do
      {:ok, _supervisor_pid, pipeline_pid} ->
        {:ok, pipeline_pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_backend(backend, _media_file, _temp_dir) do
    Logger.error("Unknown backend: #{backend}")
    {:error, :unknown_backend}
  end

  # Stop the backend process
  defp stop_backend(:ffmpeg, backend_pid) do
    Logger.info("Stopping FFmpeg backend")
    FfmpegHlsTranscoder.stop_transcoding(backend_pid)
  end

  defp stop_backend(:membrane, backend_pid) do
    Logger.info("Stopping Membrane backend")
    Membrane.Pipeline.terminate(backend_pid)
  end

  defp stop_backend(backend, _backend_pid) do
    Logger.warning("Unknown backend to stop: #{backend}")
    :ok
  end

  defp generate_session_id do
    # Generate UUID-based session ID
    UUID.uuid4()
  end

  defp update_activity(state) do
    # Cancel existing timeout check
    if state.timeout_ref do
      Process.cancel_timer(state.timeout_ref)
    end

    # Update last activity and schedule new timeout check
    state
    |> Map.put(:last_activity, DateTime.utc_now())
    |> schedule_timeout_check()
  end

  defp schedule_timeout_check(state) do
    # Check for timeout every 30 seconds (more frequent for 2-minute timeout)
    check_interval = :timer.seconds(30)
    timeout_ref = Process.send_after(self(), :check_timeout, check_interval)
    Map.put(state, :timeout_ref, timeout_ref)
  end
end
