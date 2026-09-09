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

  @registry_name Mydia.Streaming.HlsSessionRegistry

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
      :kind,
      :plan,
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

  @doc """
  Replaces this session's stream plan.

  A remux tracker is reused across requests: a browser seek aborts the response
  and immediately opens another, and `start_remux_session/3` hands back the
  running session rather than starting a second one. A later request can
  resolve a different audio track, and therefore a different plan, so the plan
  the session was started with goes stale. Leaving it stale is the exact
  failure this feature exists to remove — the dashboard describing an encode
  that is not the one running.
  """
  @spec update_plan(pid(), Mydia.Streaming.StreamPlan.t()) :: :ok
  def update_plan(pid, plan) do
    GenServer.call(pid, {:update_plan, plan})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    media_file_id = Keyword.fetch!(opts, :media_file_id)
    user_id = Keyword.fetch!(opts, :user_id)
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    kind = Keyword.get(opts, :kind, :direct)
    plan = Keyword.get(opts, :plan)

    Logger.info("Starting #{kind} playback session for file #{media_file_id}, user #{user_id}")

    # Note: Registration in HlsSessionRegistry is handled by the :via tuple in start_link
    # passed from HlsSessionSupervisor.start_direct_session/2.
    # This ensures race-free registration with metadata.

    # Create a job in the DB so it appears in the unified "Active Jobs" queue
    {:ok, job} =
      %TranscodeJob{}
      |> TranscodeJob.changeset(%{
        media_file_id: media_file_id,
        user_id: user_id,
        type: to_string(kind),
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
      mode: kind,
      kind: kind,
      plan: plan,
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
      kind: state.kind,
      plan: state.plan,
      last_activity: state.last_activity,
      # Flags for compatibility with HLS interface
      ready: true,
      backend_alive?: true
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call({:update_plan, plan}, _from, state) do
    # Both copies, deliberately. `Streaming.list_active_sessions/0` reads the
    # live process when it can and falls back to the Registry metadata when
    # that call races a shutdown, so a plan refreshed in only one place still
    # leaves a path that reports the stale one.
    #
    # `Registry.update_value/3` may only be called by the key's owner. That is
    # this process: the `:via` tuple in the child spec registered the key from
    # inside `start_link`, so the call has to happen here rather than in the
    # supervisor that asked for the refresh.
    Registry.update_value(@registry_name, registry_key(state), &Map.put(&1, :plan, plan))

    {:reply, :ok, %{state | plan: plan}}
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

  # Mirrors the keys HlsSessionSupervisor registers these sessions under.
  defp registry_key(%State{kind: :remux, media_file_id: id, user_id: user_id}),
    do: {:remux_session, id, user_id}

  defp registry_key(%State{media_file_id: id, user_id: user_id}),
    do: {:direct_session, id, user_id}

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
