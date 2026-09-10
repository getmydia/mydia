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
  alias Mydia.Library.MediaFile
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HardwareAccel
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.KeyframeLocator
  alias Mydia.Streaming.SegmentPlan
  alias Mydia.Streaming.StreamPlan
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
      :effective_start_position,
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
      :hwaccel_lease,
      :plan,
      playlist_mode: :window,
      window: nil,
      segment_waiters: %{},
      window_generation: 0,
      ready: false,
      ready_waiters: [],
      accel: :auto,
      accel_fallbacks: 0
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            media_file: Mydia.Library.MediaFile.t(),
            media_file_id: integer(),
            user_id: integer(),
            mode: :copy | :transcode,
            start_position: non_neg_integer(),
            effective_start_position: non_neg_integer() | nil,
            backend: :ffmpeg,
            backend_pid: pid() | nil,
            temp_dir: String.t(),
            last_activity: DateTime.t(),
            timeout_ref: reference() | nil,
            playlist_path: String.t() | nil,
            db_job_id: binary() | nil,
            segment_plan: Mydia.Streaming.SegmentPlan.t() | nil,
            backend_opts: keyword(),
            hwaccel_lease: reference() | nil,
            plan: StreamPlan.t() | nil,
            playlist_mode: :full | :window,
            window: Mydia.Streaming.TranscodeWindow.t() | nil,
            segment_waiters: %{non_neg_integer() => [GenServer.from()]},
            window_generation: non_neg_integer(),
            ready: boolean(),
            ready_waiters: list(),
            accel: :auto | :none,
            accel_fallbacks: non_neg_integer()
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
  segments the caller must resolve by filename as before, and `{:error,
  :out_of_range}` when `index` falls outside the plan's segment count.
  """
  @spec request_segment(pid(), non_neg_integer()) ::
          {:ok, String.t()}
          | {:error, :timeout}
          | {:error, :window_mode}
          | {:error, :out_of_range}
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

  @doc """
  Notifies the session that its backend failed to initialise hardware
  acceleration and stopped (with reason `:normal`) rather than crashing.

  `generation` guards against this exact race the same way `notify_segments/3`
  does: a backend the session has already relocated away from (a viewer seeked
  before this notification arrived) must not be allowed to restart a window
  that no longer exists.
  """
  @spec notify_hwaccel_failed(pid(), non_neg_integer(), String.t()) :: :ok
  def notify_hwaccel_failed(pid, generation, output) do
    GenServer.cast(pid, {:hwaccel_failed, generation, output})
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
      seek_keyframe: Keyword.get(opts, :seek_keyframe),
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

      segment_plan = segment_plan_for(media_file, requested_mode)

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
               requested_playlist_mode: requested_mode,
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

    # Where the first encoder seeks to. See encoder_start_position/3.
    encoder_start = encoder_start_position(segment_plan, first_index, start_position)

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

        # A :playback lease is claimed once for the whole session, not once
        # per FfmpegHlsTranscoder process -- see acquire_hwaccel_lease/0 for
        # why.
        {capabilities, hwaccel_lease} =
          maybe_acquire_hwaccel_lease(media_file, max_bitrate, max_height)

        # The keyword list a relocation reuses verbatim (see relocate/2), so it
        # has to carry everything start_backend/6 needs beyond the offset and
        # start number, which relocate overwrites per-call. :capabilities is
        # carried the same way: decided once here (or by hwaccel_fallback/2
        # after a failure), never re-derived per relocation, so a seek never
        # has to contact HardwareAccel again.
        backend_opts = [
          max_bitrate: max_bitrate,
          max_height: max_height,
          start_position: encoder_start,
          seek_keyframe: playback.seek_keyframe,
          start_number: first_index,
          grid_aligned: grid_aligned?(playlist_mode, media_file, max_bitrate, max_height),
          absolute_timestamps: playlist_mode == :full,
          playlist_mode: playlist_mode,
          audio_language: playback.audio_language,
          show_audio_language: playback.show_audio_language,
          capabilities: capabilities
        ]

        # Computed from the same opts the backend receives, so the plan and the
        # arguments describe the same encode by construction.
        plan = StreamPlan.for_hls(media_file, backend_opts)

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
              effective_start_position:
                effective_start_position(playback.seek_keyframe, encoder_start),
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
              backend_opts: backend_opts,
              hwaccel_lease: hwaccel_lease,
              plan: plan
            }

            # Schedule initial timeout check
            state = schedule_timeout_check(state)

            Phoenix.PubSub.broadcast(Mydia.PubSub, "hls_sessions", :session_started)

            {:ok, state}

          {:error, reason} ->
            Logger.error(
              "Failed to start FFmpeg backend for session #{session_id}: #{inspect(reason)}"
            )

            if hwaccel_lease, do: HardwareAccel.release(hwaccel_lease)
            File.rm_rf!(temp_dir)
            {:stop, {:backend_start_failed, reason}}
        end

      {:error, reason} ->
        Logger.error("Failed to create temp directory #{temp_dir}: #{inspect(reason)}")
        {:stop, {:temp_dir_creation_failed, reason}}
    end
  end

  # Decides whether this session is worth leasing a hardware slot for at all.
  # Only a re-encoding session ever reaches the hardware encoder --
  # reencodes_video?/3 is the exact same decision build_ffmpeg_args/3 makes
  # between "copy" and "libx264"/"h264_vaapi" -- so a stream-copy session
  # leasing a slot it will never use would only starve a session that does.
  #
  # Public only so the gating decision can be asserted directly against a
  # plain MediaFile struct, without a live HardwareAccel process, a DB row, or
  # a real init/1; nothing outside this module should call it.
  @doc false
  @spec maybe_acquire_hwaccel_lease(
          Mydia.Library.MediaFile.t() | nil,
          integer() | nil,
          integer() | nil
        ) :: {Capabilities.t() | nil, reference() | nil}
  def maybe_acquire_hwaccel_lease(media_file, max_bitrate, max_height) do
    if FfmpegHlsTranscoder.reencodes_video?(media_file, max_bitrate, max_height) do
      acquire_hwaccel_lease()
    else
      {nil, nil}
    end
  end

  # Claims a :playback hardware lease for the life of this session.
  #
  # Deliberately a session-level call, not one made by FfmpegHlsTranscoder
  # itself on every start (which is how FfmpegMp4Transcoder's :background
  # lease works -- see its init/1). FfmpegHlsTranscoder is restarted on every
  # window relocation (a seek: see relocate/2) and on every hardware-failure
  # fallback (see hwaccel_fallback/2 below), and stop_and_start_backend/3
  # deliberately overlaps the old and new backend by roughly 100ms so the
  # relocation itself never blocks the session's mailbox. A per-transcoder
  # lease would have to hold two slots during that overlap on every single
  # seek, and would be refused near the cap -- turning an ordinary seek on a
  # session that already holds a slot into a spurious software fallback.
  # Leasing once here and carrying the result through backend_opts (reused
  # verbatim by both relocate/2 and restart_backend_in_place/1) means a seek
  # never contacts HardwareAccel at all: only session start, session end, and
  # a permanent hardware-failure fallback do.
  #
  # Public only so the "not leased" fallback shape can be asserted directly
  # without a live HardwareAccel process; nothing outside this module should
  # call it.
  @doc false
  @spec acquire_hwaccel_lease() :: {Capabilities.t(), reference() | nil}
  def acquire_hwaccel_lease do
    case HardwareAccel.lease(:playback) do
      {:ok, ref} -> {HardwareAccel.capabilities(), ref}
      :refused -> {Capabilities.software("no hardware slot free for playback"), nil}
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

  # Whether the initial backend start for this session should force
  # keyframes onto the segment grid.
  #
  # Gated on playlist_mode == :full: grid alignment exists only to keep the
  # pre-computed :full playlist's uniform declared segment durations
  # accurate. A :window session has no such playlist, so forcing keyframes
  # there would change keyframe placement and segment cutting on the
  # compatibility path (the only mode wired into production today) for no
  # benefit; :window must stay exactly what it was before this feature
  # existed.
  #
  # Public only so this decision can be asserted directly; reaching it
  # through start_registered_session/7 needs a full init/1 (Registry, a DB
  # job row, a real media file), which is unrelated to whether the decision
  # itself is right. Nothing outside this module should call it.
  @doc false
  @spec grid_aligned?(
          :full | :window,
          Mydia.Library.MediaFile.t() | nil,
          integer() | nil,
          integer() | nil
        ) :: boolean()
  def grid_aligned?(playlist_mode, media_file, max_bitrate, max_height) do
    playlist_mode == :full and
      FfmpegHlsTranscoder.reencodes_video?(media_file, max_bitrate, max_height)
  end

  # Where the session's first encoder seeks to.
  #
  # A :full session starts it on the segment grid, exactly where relocate/2
  # starts every later one. Forced keyframes follow the encoder's start rather
  # than the grid, so an encoder started at the raw resume second cut every
  # segment it wrote that far off the published plan. Measured: resumed at 30s,
  # the segments declared as 28-32, 32-36 and 36-40 began at 30.00, 33.92 and
  # 37.93, and a later on-grid relocation met them with a 2s gap. The viewer
  # never sees the extra lead-in: the player seeks to the resume point inside
  # the full playlist.
  #
  # A :window session has no grid and starts where it was asked to.
  #
  # Public only so this decision can be asserted directly; nothing outside
  # this module should call it.
  @doc false
  @spec encoder_start_position(SegmentPlan.t() | nil, non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def encoder_start_position(nil, _first_index, start_position), do: start_position

  def encoder_start_position(segment_plan, first_index, _start_position),
    do: trunc(SegmentPlan.start_time(segment_plan, first_index))

  # What StartStreamingSession echoes for a :window session: the keyframe a
  # pinned stream copy begins on, or else where the first encoder started.
  defp effective_start_position(keyframe, _encoder_start) when is_number(keyframe),
    do: trunc(keyframe)

  defp effective_start_position(nil, encoder_start), do: encoder_start

  @doc """
  Adds `:seek_keyframe` to a new session's opts when its stream will begin on
  a keyframe rather than on the requested offset.

  Runs in the caller's process: `HlsSessionSupervisor.start_new_session/5`
  calls it before `DynamicSupervisor.start_child/2`, because `init/1` runs
  inside the supervisor and a keyframe lookup there would hold up every other
  session start behind it.

  Returns `opts` untouched whenever there is nothing to pin, including for a
  media file that no longer exists; `init/1` reports that one.
  """
  @spec prepare_start(term(), keyword()) :: keyword()
  def prepare_start(media_file_id, opts) do
    media_file = Library.get_media_file!(media_file_id, preload: [:library_path])
    seek_opts(media_file, opts)
  rescue
    Ecto.NoResultsError -> opts
  end

  # The containers whose seeks were measured to land where KeyframeLocator
  # predicts. An MPEG-TS copy seek lands after its target, so a pin there
  # would start the stream a GOP later than the echo claims.
  @pinnable_containers ["mkv", "mp4"]

  # Only a :window session copying its video, resumed past zero, from a
  # measured container, needs a pin. Re-encoded video already starts on the
  # second it was asked for (accurate seek, plus -copypriorss:a 0 for copied
  # audio), and a :full session echoes zero and carries real media time
  # through -copyts.
  #
  # Public only so the decision can be asserted on a hand-built file, without a
  # database row; nothing outside this module should call it.
  @doc false
  @spec seek_opts(
          MediaFile.t(),
          keyword(),
          (String.t(), number() -> {:ok, float()} | :none)
        ) :: keyword()
  def seek_opts(media_file, opts, locate \\ &KeyframeLocator.locate/2) do
    start_position = Keyword.get(opts, :start_position, 0)
    requested_mode = Keyword.get(opts, :playlist_mode, :window)

    with true <- is_integer(start_position) and start_position > 0,
         :window <- effective_playlist_mode(media_file, requested_mode),
         true <- container(media_file) in @pinnable_containers,
         false <-
           FfmpegHlsTranscoder.reencodes_video?(
             media_file,
             Keyword.get(opts, :max_bitrate),
             Keyword.get(opts, :max_height)
           ),
         path when is_binary(path) <- MediaFile.absolute_path(media_file),
         {:ok, keyframe} <- locate.(path, start_position) do
      Keyword.put(opts, :seek_keyframe, keyframe)
    else
      _ -> opts
    end
  end

  defp container(%MediaFile{metadata: %{container: container}}), do: container
  defp container(_media_file), do: nil

  # The published plan a session asking for `requested_mode` gets, or nil when
  # it runs :window. Shared by init/1 and seek_opts/3 so the two cannot
  # disagree about which mode a session ends up in; both load the file from the
  # database, so they see the same duration.
  #
  # Public only so this decision can be asserted directly; nothing outside
  # this module should call it.
  @doc false
  @spec segment_plan_for(MediaFile.t(), :full | :window) :: SegmentPlan.t() | nil
  def segment_plan_for(media_file, :full), do: plan_from_media_file(media_file)
  def segment_plan_for(_media_file, :window), do: nil

  @doc false
  @spec effective_playlist_mode(MediaFile.t(), :full | :window) :: :full | :window
  def effective_playlist_mode(media_file, requested_mode) do
    if segment_plan_for(media_file, requested_mode), do: :full, else: :window
  end

  # The keys start_backend/6 forwards to FfmpegHlsTranscoder. See the comment
  # in start_backend/6: a key the transcoder reads has to be listed here, or
  # the transcoder never sees it.
  #
  # Public only so the forwarding can be asserted without spawning FFmpeg;
  # nothing outside this module should call it.
  @doc false
  @spec transcoder_base_opts(MediaFile.t(), String.t() | nil, String.t(), keyword()) ::
          keyword()
  def transcoder_base_opts(media_file, absolute_path, temp_dir, opts) do
    [
      input_path: absolute_path,
      output_dir: temp_dir,
      media_file: media_file,
      start_position: Keyword.get(opts, :start_position, 0),
      seek_keyframe: Keyword.get(opts, :seek_keyframe),
      start_number: Keyword.get(opts, :start_number, 0),
      grid_aligned: Keyword.get(opts, :grid_aligned, false),
      absolute_timestamps: Keyword.get(opts, :absolute_timestamps, false)
    ] ++
      if(opts[:max_bitrate], do: [max_bitrate: opts[:max_bitrate]], else: []) ++
      if(opts[:max_height], do: [max_height: opts[:max_height]], else: []) ++
      if(opts[:audio_language], do: [audio_language: opts[:audio_language]], else: []) ++
      if(opts[:show_audio_language],
        do: [show_audio_language: opts[:show_audio_language]],
        else: []
      ) ++
      if(opts[:capabilities], do: [capabilities: opts[:capabilities]], else: [])
  end

  @doc """
  Decides what to do when the backend died of a hardware initialisation failure.

  Returns `{:retry, state}` with acceleration disabled for the rest of the
  session, or `:stop` when this session has already fallen back once. Public so
  the decision is testable without starting a backend.
  """
  @spec hwaccel_fallback(State.t(), non_neg_integer()) :: {:retry, State.t()} | :stop
  def hwaccel_fallback(%State{accel_fallbacks: n}, _target) when n >= 1, do: :stop

  def hwaccel_fallback(%State{} = state, target) do
    # This session is about to encode in software for the rest of its life
    # (only one fallback is ever allowed -- see the clause above), so
    # continuing to hold a hardware slot would waste it: another session could
    # be leasing it instead.
    if state.hwaccel_lease, do: HardwareAccel.release(state.hwaccel_lease)

    software =
      Capabilities.software("fell back to software after a hardware failure in this session")

    backend_opts =
      state.backend_opts
      |> Keyword.put(:capabilities, software)
      |> Keyword.put(:start_number, target)

    plan = StreamPlan.for_hls(state.media_file, backend_opts)

    # The dashboard reloads Now Playing on this. Without it a card keeps
    # advertising VAAPI after the encoder dropped to software, which is a
    # smaller copy of the bug this whole change exists to fix.
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "hls_sessions",
      {:session_updated, state.session_id}
    )

    {:retry,
     %{
       state
       | accel: :none,
         accel_fallbacks: state.accel_fallbacks + 1,
         backend_opts: backend_opts,
         hwaccel_lease: nil,
         plan: plan
     }}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    # Getting info counts as activity
    state = update_activity(state)

    info = %{
      session_id: state.session_id,
      media_file_id: state.media_file_id,
      mode: state.mode,
      # The offset this session was started for. HlsSessionSupervisor matches
      # repeat requests against it, so it stays the requested value even when
      # the stream begins elsewhere; see effective_start_position below.
      start_position: state.start_position,
      # Where the stream really begins, and what StartStreamingSession echoes
      # for a :window session: the keyframe a pinned stream copy starts on (see
      # prepare_start/2), otherwise start_position. Reported here rather than
      # left to the caller's own bookkeeping because a caller can end up
      # holding a session it did not start (HlsSessionSupervisor adopts a
      # concurrent winner, which may have started elsewhere), and a client
      # handed an offset its stream does not start at persists every position
      # wrong.
      effective_start_position: state.effective_start_position || state.start_position,
      backend: state.backend,
      temp_dir: state.temp_dir,
      last_activity: state.last_activity,
      backend_alive?: is_pid(state.backend_pid) and Process.alive?(state.backend_pid),
      playlist_mode: state.playlist_mode,
      duration: state.segment_plan && state.segment_plan.duration,
      plan: state.plan
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

  # Out of range for the published plan. TranscodeWindow.decide/2 has no
  # concept of the plan's bounds and would happily return {:relocate, index},
  # which stops the encoder the viewer is actually watching to seek FFmpeg
  # past end of file. Checked before decide/2 runs, so a bogus index never
  # touches the running backend. A negative index cannot reach here through
  # the controller (SegmentPlan.index_from_name/1's regex only matches
  # digits), but the low end is bounded too since it costs nothing.
  def handle_call({:request_segment, index}, _from, %{segment_plan: plan} = state)
      when index < 0 or index >= plan.count do
    {:reply, {:error, :out_of_range}, state}
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

  # A :window session has no TranscodeWindow to mark ready and no segment
  # waiters to answer (see start_backend/6, which no longer wires on_segments
  # for this mode). This clause is defence in depth: TranscodeWindow.mark_ready/2
  # pattern-matches %TranscodeWindow{} in its head, so a nil window here would
  # crash the whole session GenServer the moment any caller re-introduces the
  # callback for :window sessions.
  def handle_cast({:segments_ready, _generation, _indices}, %{window: nil} = state) do
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

  def handle_cast({:hwaccel_failed, generation, _output}, %{window_generation: current} = state)
      when generation != current do
    # A dead backend's failure report for a window the session has already
    # relocated away from (a viewer seeked before the notification arrived).
    # Mirrors the identical guard on {:segments_ready, ...} above.
    {:noreply, state}
  end

  # A hardware initialisation failure is recoverable: re-encode in software
  # rather than taking the session down, and bump window_generation so a late
  # report from this same dead backend (were it to somehow arrive twice) is
  # discarded by the guard clause above.
  #
  # A :full session reuses relocate/2, which already knows how to stop a
  # backend and restart it at a target segment number while preserving the
  # segment grid. A :window session has no segment grid -- both segment_plan
  # and window are nil (see start_registered_session/7) -- and never reaches
  # relocate/2 any other way (it is only ever called from
  # {:request_segment, index}, which a :window session's handle_call answers
  # with {:error, :window_mode} before relocate/2 could run). Calling
  # relocate/2 for a :window session would crash on
  # SegmentPlan.start_time(nil, _), so it gets the simpler
  # restart_backend_in_place/1 instead: same backend_opts (already forced to
  # software by hwaccel_fallback/2 below), no grid to advance.
  #
  # FfmpegHlsTranscoder stops itself with reason :normal for this case
  # specifically so the link from this session to its backend does not take
  # the session down before this callback can run (see the comment on
  # relocate/2, and on FfmpegHlsTranscoder's exit-status handler).
  def handle_cast({:hwaccel_failed, _generation, output}, state) do
    Mydia.Streaming.HardwareAccel.report_failure(
      :vaapi,
      state.media_file && state.media_file.codec
    )

    target = Keyword.get(state.backend_opts, :start_number, 0)

    case hwaccel_fallback(state, target) do
      {:retry, state} ->
        Logger.warning(
          "Session #{state.session_id}: hardware encode failed, restarting in software " <>
            "at segment #{target}"
        )

        new_state =
          case state.playlist_mode do
            :full -> relocate(%{state | backend_pid: nil}, target)
            :window -> restart_backend_in_place(%{state | backend_pid: nil})
          end

        {:noreply, new_state}

      :stop ->
        Logger.error("Session #{state.session_id}: hardware fallback already used; giving up")
        {:stop, {:backend_terminated, {:hwaccel_failed, output}}, state}
    end
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

    # Release the hardware slot on every exit path -- normal termination,
    # timeout, backend crash -- so a session that leased one at start never
    # leaks it. Already nil after a permanent software fallback (see
    # hwaccel_fallback/2), so this is a no-op then.
    if state.hwaccel_lease, do: HardwareAccel.release(state.hwaccel_lease)

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

  # Stops the current backend (unlinked first, so its exit doesn't take this
  # session down) if it is still alive, then starts a new one at
  # `opts`/`generation`. Returns exactly what start_backend/6 returns.
  #
  # Shared by relocate/2 and restart_backend_in_place/1 below: both need
  # "replace the running backend with a new one," and only differ in what
  # session state to update once that succeeds (relocate/2 also advances the
  # segment window; a :window session has no window to advance).
  defp stop_and_start_backend(state, opts, generation) do
    if is_pid(state.backend_pid) and Process.alive?(state.backend_pid) do
      Process.unlink(state.backend_pid)

      # stop_backend/2 reaches FfmpegHlsTranscoder.stop_transcoding/1, which is
      # GenServer.stop/2 and blocks until terminate/2 finishes, and
      # terminate/2 has an unconditional 100ms sleep before its SIGKILL
      # escalation check. Called inline, that freezes this session's entire
      # mailbox (every other segment request, get_info, heartbeat) for at
      # least 100ms on every relocation, in the exact path this feature
      # exists to make smooth. Task.start/1 moves the wait off this process
      # without linking or monitoring it back in, so the old encoder's exit
      # can no longer affect this session (which is the whole point of the
      # unlink above). Deliberately not Task.async/1 or
      # Task.Supervisor.async/2: both link the task to this process, which
      # reintroduces the coupling the unlink just removed.
      #
      # This does mean the old and new encoders overlap for roughly 100ms.
      # That is safe: the old backend is already unlinked and about to stop
      # producing segments, and any {:segments_ready, ...} or
      # {:hwaccel_failed, ...} it still manages to send in that window
      # carries the old generation, which the matching guard clause discards.
      backend_pid = state.backend_pid
      backend = state.backend
      Task.start(fn -> stop_backend(backend, backend_pid) end)
    end

    start_backend(:ffmpeg, state.media_file, state.temp_dir, state.db_job_id, opts, generation)
  end

  # Moves the encoder to `target`, keeping every segment already on disk.
  defp relocate(state, target) do
    generation = state.window_generation + 1

    opts =
      state.backend_opts
      |> Keyword.put(:start_position, trunc(SegmentPlan.start_time(state.segment_plan, target)))
      |> Keyword.put(:start_number, target)

    case stop_and_start_backend(state, opts, generation) do
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

  # The :window-mode counterpart to relocate/2, used only for the
  # hardware-failure fallback. A :window session has no SegmentPlan and no
  # TranscodeWindow to advance (both nil -- see start_registered_session/7),
  # so there is nothing to seek to: it just restarts the backend with its
  # existing backend_opts, which hwaccel_fallback/2 has already forced to
  # software, at a bumped window_generation so a stray late report from the
  # old backend is discarded the same way a stale relocation is.
  defp restart_backend_in_place(state) do
    generation = state.window_generation + 1

    case stop_and_start_backend(state, state.backend_opts, generation) do
      {:ok, backend_pid} ->
        Process.link(backend_pid)
        %{state | backend_pid: backend_pid, window_generation: generation}

      {:error, reason} ->
        Logger.error("Failed to restart backend in software: #{inspect(reason)}")
        %{state | backend_pid: nil, window_generation: generation}
    end
  end

  # Start FFmpeg backend
  defp start_backend(:ffmpeg, media_file, temp_dir, job_id, opts, generation) do
    # Resolve absolute path for FFmpeg input
    absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)
    Logger.info("Starting FFmpeg backend for #{absolute_path}")

    # Capture self() to notify when FFmpeg is ready
    session_pid = self()

    # Build transcoder opts, including max_bitrate and max_height if set.
    #
    # This whitelist is why HlsSession.State.plan (built from `opts`, i.e.
    # backend_opts) and FfmpegHlsTranscoder's own plan (built from
    # `transcoder_opts`, i.e. this filtered base_opts ++ the callbacks below)
    # agree today: StreamPlan.for_hls/2 also reads :video_codec, :crf and
    # :preset, none of which backend_opts currently sets, so both builds see
    # the same defaults for every key actually populated. That agreement is
    # by construction only for the keys listed here -- it is NOT "the two
    # calls share one keyword list". Adding a plan-relevant key (:video_codec,
    # :crf, :preset, or any future StreamPlan input) to backend_opts without
    # also forwarding it through this filter will desynchronise the two
    # plans silently: the dashboard (reading HlsSession.State.plan) would
    # describe an encode the transcoder never actually runs.
    base_opts = transcoder_base_opts(media_file, absolute_path, temp_dir, opts)

    # Only a :full session has a TranscodeWindow to mark ready, so only wire
    # the callback that reports segment completion for that mode. A :window
    # session has no window and no segment waiters, so notify_segments would
    # be pure overhead even if handle_cast tolerated a nil window (see the
    # {segments_ready, _, _} clause guarding on `window: nil` below).
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
          on_hwaccel_failed: fn output ->
            __MODULE__.notify_hwaccel_failed(session_pid, generation, output)
          end
        ] ++
        if Keyword.get(opts, :playlist_mode) == :full do
          [
            on_segments: fn indices ->
              __MODULE__.notify_segments(session_pid, generation, indices)
            end
          ]
        else
          []
        end

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
