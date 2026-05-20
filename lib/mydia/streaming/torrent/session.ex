defmodule Mydia.Streaming.Torrent.Session do
  @moduledoc """
  Manages a single torrent streaming session.
  """

  use GenServer, restart: :temporary

  alias Mydia.Torrent
  alias Mydia.Streaming.Torrent.Engine

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

  # Server Callbacks

  @impl true
  def init(args) do
    session_id = Keyword.fetch!(args, :session_id)
    broadcast_session_event(:session_started, session_id)
    {:ok, %State{session_id: session_id}}
  end

  @impl true
  def handle_call({:add_torrent, magnet_link}, from, state) do
    with {:ok, engine} <- Engine.get_resource() do
      case Torrent.add_torrent(engine, self(), magnet_link) do
        :ok ->
          {:noreply, %{state | torrent_resource: engine, pending_add: from}}

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
  def handle_info({:ok, _type, t_id, hash}, %{pending_add: from} = state) when not is_nil(from) do
    GenServer.reply(from, :ok)
    {:noreply, %{state | torrent_id: t_id, info_hash: hash, pending_add: nil}}
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
  def terminate(_reason, state) do
    if state.torrent_resource && state.torrent_id do
      Torrent.cancel_torrent(state.torrent_resource, state.torrent_id, false)
    end

    broadcast_session_event(:session_stopped, state.session_id)
    :ok
  end

  defp broadcast_session_event(event, _session_id) do
    Phoenix.PubSub.broadcast(Mydia.PubSub, "torrent_sessions", event)
    # Also broadcast to hls_sessions for common dashboard updates if they use it
    Phoenix.PubSub.broadcast(Mydia.PubSub, "hls_sessions", event)
  end
end
