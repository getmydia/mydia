defmodule Mydia.Streaming.HlsSession do
  @moduledoc """
  GenServer managing individual HLS transcoding sessions.

  Each session represents a single user streaming a specific media file.
  The session starts FFmpeg to transcode the file on-demand, manages
  temporary storage for HLS segments, and automatically terminates after
  a period of inactivity.

  ## Lifecycle

  1. Session started with media_file_id
  2. Creates unique session directory in /tmp
  3. Starts FFmpeg transcoding backend
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
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.SegmentPlan
  alias Mydia.Streaming.TranscodeWindow
  alias Mydia.Repo
  alias Mydia.Downloads.TranscodeJob

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
      :mode,
      :start_position,
      :max_bitrate,
      :max_height,
      :backend,
      :backend_pid,
      :temp_dir,
      :last_activity,
      :timeout_ref,
      :playlist_path,
      :db_job_id,
      :segment_plan,
      :backend_opts,
      playlist_mode: :window,
      window: nil,
      segment_waiters: %{},
      window_generation: 0,
      ready: false,
      ready_waiters: []
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            media_file: Mydia.Library.MediaFile.t(),
            media_file_id: integer(),
            user_id: integer(),
            mode: :copy | :transcode,
            start_position: non_neg_integer(),
            backend: :ffmpeg,
            backend_pid: pid() | nil,
            temp_dir: String.t(),
            last_activity: DateTime.t(),
            timeout_ref: reference() | nil,
            playlist_path: String.t() | nil,
            db_job_id: binary() | nil,
            segment_plan: Mydia.Streaming.SegmentPlan.t() | nil,
            backend_opts: keyword(),
            playlist_mode: :full | :window,
            window: Mydia.Streaming.TranscodeWindow.t() | nil,
            segment_waiters: %{non_neg_integer() => [GenServer.from()]},
            window_generation: non_neg_integer(),
            ready: boolean(),
            ready_waiters: list()
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
    * `:playlist_mode` - (optional) `:full` publishes the complete VOD
      playlist up front and serves segments on demand via
      `request_segment/2`; `:window` is the existing behaviour, where the
      client resolves segment files directly. Default `:window`. A `:full`
      request degrades to `:window` when the media file's duration is
      unknown (see `plan_from_media_file/1`).

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

  @doc """
  Waits for the session to be ready (FFmpeg has written the first playlist).

  Returns `:ok` when ready, or `{:error, :timeout}` if the timeout is reached.
  Default timeout is 30 seconds.
  """
  @spec await_ready(pid(), timeout()) :: :ok | {:error, :timeout} | {:error, term()}
  def await_ready(pid, timeout \\ 30_000) do
    GenServer.call(pid, :await_ready, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  @doc """
  Notifies the session that FFmpeg has written the first playlist.

  This is called by the FFmpeg transcoder when it detects the playlist file.
  """
  @spec notify_ready(pid()) :: :ok
  def notify_ready(pid) do
    GenServer.cast(pid, :notify_ready)
  end

  @segment_wait_timeout 10_000

  @doc """
  Resolves a segment to an on-disk path, waiting or relocating the encoder as
  needed.

  Returns `{:error, :window_mode}` for a session that has no plan, whose
  segments the caller must resolve by filename as before.
  """
  @spec request_segment(pid(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, :timeout} | {:error, :window_mode}
  def request_segment(pid, index) do
    GenServer.call(pid, {:request_segment, index}, @segment_wait_timeout + 2_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "The published playlist, or `{:error, :window_mode}` if this session has none."
  @spec playlist(pid()) :: {:ok, String.t()} | {:error, :window_mode}
  def playlist(pid), do: GenServer.call(pid, :playlist)

  @doc """
  Records segments the backend has finished writing.

  `generation` guards against a stopped backend's last poll arriving after a
  relocation has already started a new one: its indices belong to a window that
  no longer exists, and folding them in would make the session believe the new
  encoder is further along than it is.
  """
  @spec notify_segments(pid(), non_neg_integer(), [non_neg_integer()]) :: :ok
  def notify_segments(pid, generation, indices) do
    GenServer.cast(pid, {:segments_ready, generation, indices})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    media_file_id = Keyword.fetch!(opts, :media_file_id)
    user_id = Keyword.fetch!(opts, :user_id)
    registry_key = Keyword.fetch!(opts, :registry_key)
    mode = Keyword.get(opts, :mode, :transcode)
    max_bitrate = Keyword.get(opts, :max_bitrate)
    max_height = Keyword.get(opts, :max_height)
    start_position = Keyword.get(opts, :start_position, 0)

    # Everything that shapes the encoded output, carried as one map rather
    # than as a growing positional list. Registered in the Registry too, so
    # HlsSessionSupervisor.session_matches?/2 can tell whether a running
    # session can serve the next request.
    playback = %{
      max_bitrate: max_bitrate,
      max_height: max_height,
      start_position: start_position,
      audio_language: Keyword.get(opts, :audio_language),
      show_audio_language: Keyword.get(opts, :show_audio_language)
    }

    # Load media file with metadata
    try do
      # `episode: :media_item` is not decoration: a TV media_file carries a
      # null media_item_id and reaches its item through the episode, so
      # without this nested preload every episode looks like it has no
      # original language and the "original" audio preference silently does
      # nothing for the entire TV library.
      media_file =
        Library.get_media_file!(media_file_id,
          preload: [:media_item, :library_path, episode: :media_item]
        )

      # A session is only :full when the caller asked for it AND the duration is
      # actually known. ensure_duration_known/2 can come back empty when the
      # inline probe budget is exceeded, and there is no plan to publish without
      # a duration, so that session degrades to :window regardless of what the
      # client requested.
      requested_mode = Keyword.get(opts, :playlist_mode, :window)

      segment_plan =
        case requested_mode do
          :full -> plan_from_media_file(media_file)
          :window -> nil
        end

      playlist_mode = if segment_plan, do: :full, else: :window

      # Register this session in the Registry. This is a `:unique` key, so two
      # concurrent callers can race here (e.g. HlsSessionSupervisor replacing a
      # session on an offset mismatch from two overlapping requests for the
      # same media_file_id/user_id). Only one registration wins; the loser
      # must stop rather than run an invisible, unregistered FFmpeg process
      # that get_session/2 could never find. See
      # HlsSessionSupervisor.start_new_session/5, which adopts the winner's
      # pid instead of treating this as a failure. Registration happens
      # before the temp directory is created and before start_backend/6
      # spawns FFmpeg, so the losing branch below spawns no process and
      # leaks nothing.
      case Registry.register(
             Mydia.Streaming.HlsSessionRegistry,
             registry_key,
             %{
               media_file_id: media_file_id,
               user_id: user_id,
               mode: mode,
               start_position: start_position,
               max_bitrate: max_bitrate,
               max_height: max_height,
               audio_language: playback.audio_language,
               show_audio_language: playback.show_audio_language,
               playlist_mode: playlist_mode,
               started_at: DateTime.utc_now()
             }
           ) do
        {:ok, _owner} ->
          start_registered_session(
            media_file_id,
            user_id,
            mode,
            media_file,
            playback,
            segment_plan,
            playlist_mode
          )

        {:error, {:already_registered, pid}} ->
          {:stop, {:already_registered, pid}}
      end
    rescue
      Ecto.NoResultsError ->
        Logger.error("Media file #{media_file_id} not found")
        {:stop, :media_file_not_found}
    end
  end

  # Continues session setup once this process has won the registration race
  # for its (media_file_id, user_id) key. Creates the temp dir, the DB job
  # record, and starts the FFmpeg backend.
  defp start_registered_session(
         media_file_id,
         user_id,
         mode,
         media_file,
         playback,
         segment_plan,
         playlist_mode
       ) do
    %{max_bitrate: max_bitrate, max_height: max_height, start_position: start_position} = playback

    # The segment the running encoder has to start from. Only meaningful for a
    # :full session: a :window session has no plan to index into, and its
    # first_index is never consulted (there is no window to seed).
    first_index =
      if segment_plan, do: SegmentPlan.index_for_time(segment_plan, start_position), else: 0

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

        # Create DB record for the unified queue
        {:ok, job} =
          %TranscodeJob{}
          |> TranscodeJob.changeset(%{
            media_file_id: media_file_id,
            user_id: user_id,
            type: "stream",
            status: "transcoding",
            # Informational only
            resolution:
              if(media_file.resolution in ["1080p", "720p", "480p"],
                do: media_file.resolution,
                else: "original"
              ),
            progress: 0.0,
            started_at: DateTime.utc_now()
          })
          |> Repo.insert()

        Mydia.Downloads.broadcast_job_update(job.id)

        Mydia.Streaming.emit_playback_started(media_file_id, user_id)

        Logger.info("Temp directory: #{temp_dir}")
        Logger.info("Starting HLS transcoding with FFmpeg backend")

        # The keyword list a relocation reuses verbatim (see relocate/2), so it
        # has to carry everything start_backend/6 needs beyond the offset and
        # start number, which relocate overwrites per-call.
        backend_opts = [
          max_bitrate: max_bitrate,
          max_height: max_height,
          start_position: start_position,
          start_number: first_index,
          grid_aligned: FfmpegHlsTranscoder.reencodes_video?(media_file, max_bitrate),
          audio_language: playback.audio_language,
          show_audio_language: playback.show_audio_language
        ]

        # Start FFmpeg backend
        case start_backend(:ffmpeg, media_file, temp_dir, job.id, backend_opts, 0) do
          {:ok, backend_pid} ->
            # Link to backend process so we terminate if it crashes
            Process.link(backend_pid)

            state = %State{
              session_id: session_id,
              media_file: media_file,
              media_file_id: media_file_id,
              user_id: user_id,
              mode: mode,
              start_position: start_position,
              max_bitrate: max_bitrate,
              max_height: max_height,
              backend: :ffmpeg,
              backend_pid: backend_pid,
              temp_dir: temp_dir,
              last_activity: DateTime.utc_now(),
              db_job_id: job.id,
              segment_plan: segment_plan,
              playlist_mode: playlist_mode,
              window: if(playlist_mode == :full, do: TranscodeWindow.new(first_index), else: nil),
              backend_opts: backend_opts
            }

            # Schedule initial timeout check
            state = schedule_timeout_check(state)

            Phoenix.PubSub.broadcast(Mydia.PubSub, "hls_sessions", :session_started)

            {:ok, state}

          {:error, reason} ->
            Logger.error(
              "Failed to start FFmpeg backend for session #{session_id}: #{inspect(reason)}"
            )

            File.rm_rf!(temp_dir)
            {:stop, {:backend_start_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to create temp directory #{temp_dir}: #{inspect(reason)}")
        {:stop, {:temp_dir_creation_failed, reason}}
    end
  end

  # The duration ffprobe recorded at analyze time, or whatever the resolver's
  # inline probe managed to fill in. nil means no plan and no full playlist.
  defp plan_from_media_file(%{metadata: %{duration: duration}}) when is_number(duration) do
    case SegmentPlan.build(duration) do
      {:ok, plan} -> plan
      :error -> nil
    end
  end

  defp plan_from_media_file(_media_file), do: nil

  @impl true
  def handle_call(:get_info, _from, state) do
    # Getting info counts as activity
    state = update_activity(state)

    info = %{
      session_id: state.session_id,
      media_file_id: state.media_file_id,
      mode: state.mode,
      # The offset this session is actually transcoding from. Reported here
      # rather than left to the caller's own bookkeeping because a caller can
      # end up holding a session it did not start — HlsSessionSupervisor
      # adopts a concurrent winner, and that winner may have been started from
      # a different offset. Echoing the requested value instead of this one
      # would hand the client a timeline shifted against the stream it is
      # actually playing, and every position it persisted would be wrong.
      start_position: state.start_position,
      backend: state.backend,
      temp_dir: state.temp_dir,
      last_activity: state.last_activity,
      backend_alive?: is_pid(state.backend_pid) and Process.alive?(state.backend_pid),
      playlist_mode: state.playlist_mode,
      duration: state.segment_plan && state.segment_plan.duration
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:get_playlist_path, _from, state) do
    {:reply, {:ok, state.playlist_path}, state}
  end

  def handle_call(:playlist, _from, %{segment_plan: nil} = state) do
    {:reply, {:error, :window_mode}, state}
  end

  def handle_call(:playlist, _from, state) do
    state = update_activity(state)
    {:reply, {:ok, SegmentPlan.playlist(state.segment_plan)}, state}
  end

  def handle_call({:request_segment, _index}, _from, %{segment_plan: nil} = state) do
    {:reply, {:error, :window_mode}, state}
  end

  def handle_call({:request_segment, index}, from, state) do
    state = update_activity(state)

    case TranscodeWindow.decide(state.window, index) do
      :serve ->
        {:reply, {:ok, segment_path(state, index)}, state}

      :wait ->
        {:noreply, park_waiter(state, index, from)}

      {:relocate, target} ->
        {:noreply, state |> relocate(target) |> park_waiter(index, from)}
    end
  end

  def handle_call(:await_ready, _from, %{ready: true} = state) do
    # Already ready, reply immediately
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, from, state) do
    # Not ready yet, add to waiters list (we'll reply when ready)
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    state = update_activity(state)
    {:noreply, state}
  end

  def handle_cast({:cache_playlist_path, path}, state) do
    {:noreply, %{state | playlist_path: path}}
  end

  def handle_cast(:notify_ready, %{ready: true} = state) do
    # Already notified, ignore duplicate
    {:noreply, state}
  end

  def handle_cast(:notify_ready, state) do
    Logger.info("Session #{state.session_id} is ready (playlist available)")

    # Reply to all waiters, catching failures if waiter processes have terminated
    Enum.each(state.ready_waiters, fn from ->
      try do
        GenServer.reply(from, :ok)
      catch
        :exit, _ ->
          # Waiter process has terminated, ignore
          :ok
      end
    end)

    {:noreply, %{state | ready: true, ready_waiters: []}}
  end

  def handle_cast({:segments_ready, generation, _indices}, %{window_generation: current} = state)
      when generation != current do
    # A dead backend's final poll. Its indices belong to a window that has
    # already been replaced.
    {:noreply, state}
  end

  def handle_cast({:segments_ready, _generation, indices}, state) do
    window = TranscodeWindow.mark_ready(state.window, indices)

    {waiters, remaining} = Map.split(state.segment_waiters, indices)

    Enum.each(waiters, fn {index, froms} ->
      path = segment_path(state, index)
      Enum.each(froms, &safe_reply(&1, {:ok, path}))
    end)

    {:noreply, %{state | window: window, segment_waiters: remaining}}
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

  def handle_info({:waiter_timeout, index, from}, state) do
    # Answered already, or still parked. Only the still-parked case needs a
    # reply, and it must be removed so a later segment arrival does not reply
    # to the same caller twice.
    case Map.get(state.segment_waiters, index) do
      nil ->
        {:noreply, state}

      froms ->
        if from in froms do
          safe_reply(from, {:error, :timeout})
          remaining = List.delete(froms, from)

          waiters =
            if remaining == [],
              do: Map.delete(state.segment_waiters, index),
              else: Map.put(state.segment_waiters, index, remaining)

          {:noreply, %{state | segment_waiters: waiters}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Unhandled message in HlsSession: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating HLS session #{state.session_id}, reason: #{inspect(reason)}")

    Phoenix.PubSub.broadcast(Mydia.PubSub, "hls_sessions", :session_ended)

    # Remove the job from the database
    if state.db_job_id do
      case Repo.get(TranscodeJob, state.db_job_id) do
        nil ->
          :ok

        job ->
          Repo.delete(job)
          Mydia.Downloads.broadcast_job_update(job.id)
      end
    end

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

  defp segment_path(state, index) do
    Path.join(state.temp_dir, SegmentPlan.segment_name(index))
  end

  defp park_waiter(state, index, from) do
    Process.send_after(self(), {:waiter_timeout, index, from}, @segment_wait_timeout)

    %{
      state
      | segment_waiters: Map.update(state.segment_waiters, index, [from], &[from | &1])
    }
  end

  # A waiter's caller can die between parking and the reply. GenServer.reply/2
  # to a dead caller exits, which would take the whole session down with it.
  defp safe_reply(from, message) do
    GenServer.reply(from, message)
  catch
    :exit, _reason -> :ok
  end

  # Moves the encoder to `target`, keeping every segment already on disk.
  #
  # The backend is unlinked before it is stopped. HlsSession links to its
  # backend so a crashed encoder takes the session down; without the unlink, a
  # deliberate stop would do the same thing and every seek would kill the
  # session.
  defp relocate(state, target) do
    generation = state.window_generation + 1

    if is_pid(state.backend_pid) and Process.alive?(state.backend_pid) do
      Process.unlink(state.backend_pid)
      stop_backend(state.backend, state.backend_pid)
    end

    opts =
      state.backend_opts
      |> Keyword.put(:start_position, trunc(SegmentPlan.start_time(state.segment_plan, target)))
      |> Keyword.put(:start_number, target)

    case start_backend(
           :ffmpeg,
           state.media_file,
           state.temp_dir,
           state.db_job_id,
           opts,
           generation
         ) do
      {:ok, backend_pid} ->
        Process.link(backend_pid)

        %{
          state
          | backend_pid: backend_pid,
            window: TranscodeWindow.relocate(state.window, target),
            window_generation: generation
        }

      {:error, reason} ->
        Logger.error("Failed to relocate FFmpeg to segment #{target}: #{inspect(reason)}")

        %{
          state
          | backend_pid: nil,
            window: TranscodeWindow.stopped(state.window),
            window_generation: generation
        }
    end
  end

  # Start FFmpeg backend
  defp start_backend(:ffmpeg, media_file, temp_dir, job_id, opts, generation) do
    # Resolve absolute path for FFmpeg input
    absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)
    Logger.info("Starting FFmpeg backend for #{absolute_path}")

    # Capture self() to notify when FFmpeg is ready
    session_pid = self()

    # Build transcoder opts, including max_bitrate and max_height if set
    base_opts =
      [
        input_path: absolute_path,
        output_dir: temp_dir,
        media_file: media_file,
        start_position: Keyword.get(opts, :start_position, 0),
        start_number: Keyword.get(opts, :start_number, 0),
        grid_aligned: Keyword.get(opts, :grid_aligned, false)
      ] ++
        if(opts[:max_bitrate], do: [max_bitrate: opts[:max_bitrate]], else: []) ++
        if(opts[:max_height], do: [max_height: opts[:max_height]], else: []) ++
        if(opts[:audio_language], do: [audio_language: opts[:audio_language]], else: []) ++
        if(opts[:show_audio_language],
          do: [show_audio_language: opts[:show_audio_language]],
          else: []
        )

    transcoder_opts =
      base_opts ++
        [
          on_ready: fn ->
            __MODULE__.notify_ready(session_pid)
          end,
          on_progress: fn progress ->
            if progress[:percentage] do
              # Convert percentage 0-100 to float 0.0-1.0
              normalized_progress = progress.percentage / 100.0
              # Clamp to 0.99 for streaming (it's never fully "done" until stream ends)
              normalized_progress = min(normalized_progress, 0.99)

              # Fire and forget update to avoid bottleneck
              Task.start(fn ->
                Mydia.Downloads.TranscodeJob
                |> Repo.get(job_id)
                |> case do
                  nil ->
                    :ok

                  job ->
                    Mydia.Downloads.update_job_progress(job, normalized_progress)
                end
              end)
            end
          end,
          on_complete: fn ->
            Logger.info("FFmpeg transcoding completed for #{absolute_path}")
          end,
          on_error: fn error ->
            Logger.error("FFmpeg transcoding error for #{absolute_path}: #{error}")
          end,
          on_segments: fn indices ->
            __MODULE__.notify_segments(session_pid, generation, indices)
          end
        ]

    # Overridable per-session so a test can drive relocation without spawning
    # real FFmpeg (see test/mydia/streaming/hls_session_segments_test.exs).
    # Threaded through opts rather than global Application config: relocate/2
    # reuses state.backend_opts verbatim on every call, so a value set once at
    # session construction survives every relocation with no global state and
    # no async: false, unlike Application.get_env(:mydia, :transcoder_module)
    # (see Mydia.Downloads.JobManager for that pattern).
    transcoder = Keyword.get(opts, :transcoder_module, FfmpegHlsTranscoder)

    case transcoder.start_transcoding(transcoder_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_backend(backend, _media_file, _temp_dir, _job_id, _opts, _generation) do
    Logger.error("Unknown backend: #{backend}")
    {:error, :unknown_backend}
  end

  # Stop the backend process
  defp stop_backend(:ffmpeg, backend_pid) do
    Logger.info("Stopping FFmpeg backend")
    FfmpegHlsTranscoder.stop_transcoding(backend_pid)
  end

  defp stop_backend(backend, _backend_pid) do
    Logger.warning("Unknown backend to stop: #{backend}")
    :ok
  end

  defp generate_session_id do
    # Generate UUID-based session ID
    Ecto.UUID.generate()
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
