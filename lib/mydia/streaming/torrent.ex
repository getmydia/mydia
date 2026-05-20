defmodule Mydia.Streaming.Torrent do
  @moduledoc """
  The Torrent streaming context.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo

  alias Mydia.Streaming.Torrent.SessionSupervisor
  alias Mydia.Streaming.Torrent.Session
  alias Mydia.Streaming.Torrent.SessionSchema
  alias Mydia.Streaming.Torrent.Promotion

  @doc """
  Starts a torrent streaming session.
  """
  def start_session(attrs \\ %{}) do
    with {:ok, session} <- create_session_record(attrs),
         {:ok, pid} <- SessionSupervisor.start_session(session.id) do
      {:ok, %{session: session, pid: pid}}
    end
  end

  @doc """
  Checks if a session should be promoted and initiates it if so.
  """
  def check_and_promote(session_id) do
    with {:ok, %{session: session}} <- get_active_session(session_id) do
      # Get current progress for the content
      progress =
        cond do
          session.media_item_id ->
            Mydia.Playback.get_progress(session.user_id, media_item_id: session.media_item_id)

          session.episode_id ->
            Mydia.Playback.get_progress(session.user_id, episode_id: session.episode_id)

          true ->
            nil
        end

      # If progress > 90%, initiate promotion
      if progress && progress.completion_percentage >= 90.0 do
        Promotion.promote(session_id)
      else
        {:ok, :not_ready}
      end
    end
  end

  @doc """
  Gets an active session by ID.
  """
  def get_active_session(session_id) do
    with {:ok, pid} <- SessionSupervisor.get_session(session_id),
         session when not is_nil(session) <- Repo.get(SessionSchema, session_id) do
      {:ok, %{session: session, pid: pid}}
    else
      {:error, :not_found} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Adds a torrent to an active session.
  """
  def add_torrent(session_id, magnet_link) do
    with {:ok, %{pid: pid}} <- get_active_session(session_id) do
      Session.add_torrent(pid, magnet_link)
    end
  end

  @doc """
  Reads a chunk from a torrent session.
  """
  def read_chunk(session_id, file_index, offset, length) do
    with {:ok, %{pid: pid}} <- get_active_session(session_id) do
      Session.read_chunk(pid, file_index, offset, length)
    end
  end

  @doc """
  Stops a torrent session.
  """
  def stop_session(session_id) do
    SessionSupervisor.stop_session(session_id)
    # Optionally mark the session record as closed in DB
    Repo.get(SessionSchema, session_id)
    |> case do
      nil -> :ok
      record -> Repo.delete(record)
    end
  end

  @doc """
  Lists all active torrent streaming sessions.
  """
  def list_active_sessions do
    SessionSupervisor.list_sessions()
    |> Enum.map(fn {session_id, _pid, _meta} ->
      Repo.get(SessionSchema, session_id)
      |> Repo.preload([:user, :media_item, episode: :media_item])
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Database Helpers

  defp create_session_record(attrs) do
    %SessionSchema{}
    |> SessionSchema.changeset(
      Map.put_new(attrs, :started_at, DateTime.utc_now() |> DateTime.truncate(:second))
    )
    |> Repo.insert()
  end
end
