defmodule Mydia.Streaming do
  @moduledoc """
  Context module for streaming functionality.
  """

  alias Mydia.Streaming.HlsSessionSupervisor
  alias Mydia.Streaming.HlsSession
  alias Mydia.Library
  alias Mydia.Accounts.User
  alias Mydia.Repo

  defmodule ActiveSession do
    defstruct [
      :session_id,
      :user,
      :media_title,
      :media_type,
      :episode_info,
      :mode,
      :started_at,
      :ready
    ]
  end

  @doc """
  Lists all active streaming sessions (HLS and Torrent) with enriched metadata.

  Returns a list of `ActiveSession` structs.
  """
  def list_active_sessions do
    hls_sessions = list_active_hls_sessions()
    torrent_sessions = list_active_torrent_sessions()

    (hls_sessions ++ torrent_sessions)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  defp list_active_hls_sessions do
    HlsSessionSupervisor.list_sessions()
    |> Enum.map(fn {_key, pid, meta} ->
      # Get fresh info from the session process if alive
      info =
        case HlsSession.get_info(pid) do
          {:ok, info} -> info
          _ -> nil
        end

      # Fallback to registry meta if process call fails (race condition)
      user_id = meta[:user_id]
      media_file_id = meta[:media_file_id]
      # Default start time from registry meta; fall back to session last_activity or now
      started_at =
        meta[:started_at] ||
          (info && info[:last_activity]) ||
          DateTime.utc_now()

      # Default to transcode if missing in meta
      mode = meta[:mode] || :transcode

      # If we got info from PID, prefer that (though meta should be static)
      mode = if info, do: info.mode, else: mode
      session_id = if info, do: info.session_id, else: "unknown"
      # Default to false when missing to avoid KeyError
      ready =
        if info do
          Map.get(info, :ready, false)
        else
          Map.get(meta, :ready, false)
        end

      # Fetch User
      user = Repo.get(User, user_id)

      # Fetch Media Info - use non-raising query to handle deleted files gracefully
      media_file = Library.get_media_file(media_file_id, preload: [:media_item, :episode])

      # Return nil if media file or media_item doesn't exist (will be filtered out below)
      if media_file && media_file.media_item do
        # Derive title/type
        {title, type, episode_info} =
          case media_file do
            %{episode: %{season_number: s, episode_number: e, title: ep_title}, media_item: show} ->
              {show.title, :tv_show, "S#{pad(s)}E#{pad(e)} - #{ep_title}"}

            %{media_item: movie} ->
              {movie.title, :movie, nil}
          end

        %ActiveSession{
          session_id: session_id,
          user: user,
          media_title: title,
          media_type: type,
          episode_info: episode_info,
          mode: mode,
          started_at: started_at,
          ready: ready
        }
      else
        nil
      end
    end)
    # Filter out sessions where user or media might be missing (deleted)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.user != nil))
  end

  defp list_active_torrent_sessions do
    Mydia.Streaming.Torrent.list_active_sessions()
    |> Enum.map(fn session ->
      {title, type, episode_info} =
        case session do
          %{episode: %{season_number: s, episode_number: e, title: ep_title}, media_item: show} ->
            {show.title, :tv_show, "S#{pad(s)}E#{pad(e)} - #{ep_title}"}

          %{media_item: movie} ->
            {movie.title, :movie, nil}

          %{release_title: release_title} ->
            {release_title, :movie, nil}
        end

      %ActiveSession{
        session_id: session.id,
        user: session.user,
        media_title: title,
        media_type: type,
        episode_info: episode_info,
        mode: :torrent,
        started_at: session.started_at,
        ready: session.state == :ready
      }
    end)
  end

  defp pad(num), do: String.pad_leading("#{num}", 2, "0")
end
