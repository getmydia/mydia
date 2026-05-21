defmodule Mydia.Streaming.Torrent.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor managing torrent streaming sessions.
  """

  use DynamicSupervisor

  alias Mydia.Streaming.Torrent.Session

  @registry_name Mydia.Streaming.TorrentSessionRegistry

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new torrent session for a given session ID.
  """
  def start_session(session_id) do
    case Registry.lookup(@registry_name, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        name = {:via, Registry, {@registry_name, session_id}}
        session_opts = [session_id: session_id, name: name]

        child_spec = %{
          id: {Session, session_id},
          start: {Session, :start_link, [session_opts]},
          restart: :temporary
        }

        with {:ok, pid} <- DynamicSupervisor.start_child(__MODULE__, child_spec) do
          Phoenix.PubSub.broadcast(Mydia.PubSub, "torrent_sessions", :session_started)
          {:ok, pid}
        end
    end
  end

  @doc """
  Gets an existing torrent session by session ID.
  """
  def get_session(session_id) do
    case Registry.lookup(@registry_name, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops a torrent session by session ID.
  """
  def stop_session(session_id) do
    case get_session(session_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Phoenix.PubSub.broadcast(Mydia.PubSub, "torrent_sessions", :session_stopped)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Lists all active torrent sessions.
  """
  def list_sessions do
    Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end
end
