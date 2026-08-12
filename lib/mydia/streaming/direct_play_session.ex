defmodule Mydia.Streaming.DirectPlaySession do
  @moduledoc """
  GenServer for tracking Direct Play sessions.

  Unlike HLS sessions, this process does not perform any transcoding.
  It exists solely to:
  1. Track active viewers in the system registry.
  2. Maintain a "playing" job in the database for the unified queue.
  3. Handle timeouts to clean up when the user stops watching.
  """

  use GenServer
  require Logger

  alias Mydia.Repo
  alias Mydia.Downloads.TranscodeJob

  # Default timeout is 10 minutes
  @session_timeout Application.compile_env(
                     :mydia,
                     [:streaming, :session_timeout],
                     :timer.minutes(10)
                   )

  defmodule State do
    @moduledoc false
    defstruct [
      :session_id,
      :media_file_id,
      :user_id,
      :mode,
      :last_activity,
      :timeout_ref,
      :db_job_id
    ]
  end

  ## Client API

  @doc """
  Starts a Direct Play tracking session.
  """
  def start_link(opts) do
    # Name registration via Registry handles race conditions from parallel requests
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets session information.
  Compatible with HlsSession.get_info/1 interface.
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
  Stops the session.
  """
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    media_file_id = Keyword.fetch!(opts, :media_file_id)
    user_id = Keyword.fetch!(opts, :user_id)
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())

    Logger.info("Starting Direct Play session for file #{media_file_id}, user #{user_id}")

    # Note: Registration in HlsSessionRegistry is handled by the :via tuple in start_link
    # passed from HlsSessionSupervisor.start_direct_session/2.
    # This ensures race-free registration with metadata.

    # Create a job in the DB so it appears in the unified "Active Jobs" queue
    {:ok, job} =
      %TranscodeJob{}
      |> TranscodeJob.changeset(%{
        media_file_id: media_file_id,
        user_id: user_id,
        type: "direct",
        status: "playing",
        resolution: "original",
        progress: 0.0,
        started_at: started_at
      })
      |> Repo.insert()

    Mydia.Downloads.broadcast_job_update(job.id)

    Mydia.Streaming.emit_playback_started(media_file_id, user_id)

    # Generate a session ID (mostly for compatibility with list_active_sessions)
    session_id = Ecto.UUID.generate()

    state = %State{
      session_id: session_id,
      media_file_id: media_file_id,
      user_id: user_id,
      mode: :direct,
      db_job_id: job.id,
      last_activity: DateTime.utc_now()
    }

    state = schedule_timeout_check(state)

    Phoenix.PubSub.broadcast(Mydia.PubSub, "hls_sessions", :session_started)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    state = update_activity(state)

    info = %{
      session_id: state.session_id,
      media_file_id: state.media_file_id,
      mode: state.mode,
      last_activity: state.last_activity,
      # Flags for compatibility with HLS interface
      ready: true,
      backend_alive?: true
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    state = update_activity(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_timeout, state) do
    now = DateTime.utc_now()
    inactive_duration = DateTime.diff(now, state.last_activity, :millisecond)

    if inactive_duration >= @session_timeout do
      Logger.info(
        "Direct Play session #{state.session_id} inactive for #{inactive_duration}ms, terminating"
      )

      {:stop, :timeout, state}
    else
      state = schedule_timeout_check(state)
      {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Terminating Direct Play session #{state.session_id}, reason: #{inspect(reason)}")

    Phoenix.PubSub.broadcast(Mydia.PubSub, "hls_sessions", :session_ended)

    if state.db_job_id do
      case Repo.get(TranscodeJob, state.db_job_id) do
        nil ->
          :ok

        job ->
          Repo.delete(job)
          Mydia.Downloads.broadcast_job_update(job.id)
      end
    end

    :ok
  end

  ## Helpers

  defp update_activity(state) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)

    state
    |> Map.put(:last_activity, DateTime.utc_now())
    |> schedule_timeout_check()
  end

  defp schedule_timeout_check(state) do
    check_interval = :timer.seconds(30)
    timeout_ref = Process.send_after(self(), :check_timeout, check_interval)
    Map.put(state, :timeout_ref, timeout_ref)
  end
end
