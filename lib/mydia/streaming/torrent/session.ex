defmodule Mydia.Streaming.Torrent.Session do
  @moduledoc """
  Manages a single torrent streaming session.
  """

  use GenServer, restart: :temporary

  require Logger
  alias Mydia.Repo
  alias Mydia.Torrent
  alias Mydia.Streaming.Torrent.Engine
  alias Mydia.Streaming.Torrent.SessionSchema

  defmodule State do
    defstruct [:session_id, :torrent_resource, :torrent_id, :info_hash, :metadata, :pending_add]
  end

  # Client API

  def start_link(args) do
    {name_opts, _} = Keyword.split(args, [:name])
    GenServer.start_link(__MODULE__, args, name_opts)
  end

  def add_torrent(pid, magnet_link) do
    GenServer.call(pid, {:add_torrent, magnet_link}, 30_000)
  end

  def read_chunk(pid, file_index, offset, length) do
    GenServer.call(pid, {:read_chunk, file_index, offset, length}, 60_000)
  end

  @doc """
  Returns a snapshot of the active torrent's resource handle and id.

  Fast GenServer.call used by the P2P stream handler to bypass the Session
  process on the read-bytes hot path: the handler grabs the resource +
  torrent_id once per read, then calls the DirtyIo NIF directly so two
  concurrent readers don't serialize through this GenServer's mailbox.

  Returns:

    * `{:ok, %{resource: ResourceArc.t(), torrent_id: integer()}}` when ready.
    * `{:error, :not_ready}` when metadata hasn't resolved yet.
  """
  def get_torrent_info(pid) do
    GenServer.call(pid, :get_torrent_info, 5_000)
  end

  # Server Callbacks

  @impl true
  def init(args) do
    session_id = Keyword.fetch!(args, :session_id)
    # Note: SessionSupervisor.start_session/1 already broadcasts :session_started
    # on supervisor child start. Don't double-broadcast here.
    {:ok, %State{session_id: session_id}}
  end

  @impl true
  # Guard against concurrent add_torrent calls overwriting pending_add.
  def handle_call({:add_torrent, _}, _from, %{pending_add: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :add_in_progress}, state}
  end

  @impl true
  def handle_call({:add_torrent, magnet_link}, from, state) do
    with {:ok, engine} <- Engine.get_resource() do
      case Torrent.add_torrent(engine, self(), magnet_link) do
        :ok ->
          # Pre-stash the info_hash from the magnet so terminate/2 can cancel
          # a pre-metadata torrent without a torrent_id.
          info_hash = extract_infohash_from_magnet(magnet_link)

          {:noreply, %{state | torrent_resource: engine, pending_add: from, info_hash: info_hash}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read_chunk, file_index, offset, length}, _from, state) do
    if state.torrent_resource && state.torrent_id do
      case Torrent.read_chunk(
             state.torrent_resource,
             state.torrent_id,
             file_index,
             offset,
             length
           ) do
        {:ok, data} -> {:reply, {:ok, data}, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :no_torrent_added}, state}
    end
  end

  @impl true
  def handle_call(:get_torrent_info, _from, state) do
    if state.torrent_resource && state.torrent_id do
      {:reply, {:ok, %{resource: state.torrent_resource, torrent_id: state.torrent_id}}, state}
    else
      {:reply, {:error, :not_ready}, state}
    end
  end

  @impl true
  def handle_info(
        {:ok, _type, t_id, hash, file_id, staging_path, total_bytes},
        %{pending_add: from} = state
      )
      when not is_nil(from) do
    case persist_torrent_metadata(state.session_id, hash, file_id, staging_path, total_bytes) do
      {:ok, _session} ->
        GenServer.reply(from, :ok)
        {:noreply, %{state | torrent_id: t_id, info_hash: hash, pending_add: nil}}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending_add: nil}}
    end
  end

  @impl true
  def handle_info({:error, reason}, %{pending_add: from} = state) when not is_nil(from) do
    GenServer.reply(from, {:error, reason})
    {:noreply, %{state | pending_add: nil}}
  end

  # Handle other async messages from Rust if needed
  @impl true
  def handle_info(msg, state) do
    require Logger
    Logger.debug("Torrent Session received async message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Cancel any active torrent in the engine. If we have a torrent_id, use it;
    # otherwise fall back to the pre-metadata case (no torrent_id yet) by
    # calling the cancel-by-infohash path. Both paths pass delete_files: true so
    # the staging file is cleaned up on cancel/crash. Successful promotion
    # happens via the Promotion module, which moves the file before this
    # GenServer terminates.
    cond do
      state.torrent_resource && state.torrent_id ->
        Torrent.cancel_torrent(state.torrent_resource, state.torrent_id, true)

      state.torrent_resource && is_binary(state.info_hash) ->
        case Torrent.cancel_torrent_by_infohash(state.torrent_resource, state.info_hash, true) do
          :ok ->
            :ok

          {:error, cancel_reason} ->
            Logger.warning(
              "cancel_torrent_by_infohash failed for session #{state.session_id}: " <>
                inspect(cancel_reason)
            )
        end

      true ->
        :ok
    end

    # Best-effort: when the GenServer crashed (reason != :normal/:shutdown),
    # mark the DB row as :failed so the admin dashboard reflects reality.
    if reason not in [:normal, :shutdown] do
      update_session_state_on_crash(state.session_id, reason)
    end

    broadcast_session_event(:session_stopped, state.session_id)
    :ok
  end

  defp update_session_state_on_crash(session_id, reason) do
    case Repo.get(SessionSchema, session_id) do
      nil ->
        :ok

      session ->
        # Don't downgrade a session that already reached a terminal state.
        if session.state in [:completed, :failed, :cancelled] do
          :ok
        else
          session
          |> SessionSchema.changeset(%{state: :failed})
          |> Repo.update()

          Logger.warning(
            "Torrent session #{session_id} terminated unexpectedly: #{inspect(reason)}"
          )

          :ok
        end
    end
  end

  defp broadcast_session_event(event, _session_id) do
    # Single broadcast on the torrent_sessions topic. The cross-broadcast to
    # "hls_sessions" was double-firing dashboard updates and has been removed;
    # subscribers should listen on both topics directly if they need both.
    Phoenix.PubSub.broadcast(Mydia.PubSub, "torrent_sessions", event)
  end

  # Best-effort infohash extraction from a magnet URI.
  defp extract_infohash_from_magnet(magnet) when is_binary(magnet) do
    case Regex.run(~r/xt=urn:btih:([A-Za-z0-9]+)/i, magnet) do
      [_, hash] -> String.downcase(hash)
      _ -> nil
    end
  end

  defp extract_infohash_from_magnet(_), do: nil

  defp persist_torrent_metadata(session_id, infohash, file_id, staging_path, total_bytes) do
    case Repo.get(SessionSchema, session_id) do
      nil ->
        {:error, :session_not_found}

      session ->
        session
        |> SessionSchema.changeset(%{
          infohash: infohash,
          file_id: file_id,
          staging_path: staging_path,
          total_bytes: total_bytes,
          state: :downloading
        })
        |> Repo.update()
    end
  end
end
