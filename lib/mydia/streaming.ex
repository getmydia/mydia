defmodule Mydia.Streaming do
  @moduledoc """
  Context module for streaming functionality.
  """

  alias Mydia.Streaming.HlsSessionSupervisor
  alias Mydia.Streaming.HlsSession
  alias Mydia.Library
  alias Mydia.Accounts.User
  alias Mydia.Events
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
      :ready,
      :media_file_id,
      :bitrate_bps,
      :position_seconds,
      :duration_seconds,
      :poster_path
    ]
  end

  @doc """
  Lists all active HLS streaming sessions with enriched metadata.

  Returns a list of `ActiveSession` structs.
  """
  def list_active_sessions do
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

        progress = user && Mydia.Playback.get_progress(user.id, progress_content_id(media_file))

        %ActiveSession{
          session_id: session_id,
          user: user,
          media_title: title,
          media_type: type,
          episode_info: episode_info,
          mode: mode,
          started_at: started_at,
          ready: ready,
          media_file_id: media_file_id,
          bitrate_bps: media_file.bitrate,
          position_seconds: progress && progress.position_seconds,
          duration_seconds: progress && progress.duration_seconds,
          poster_path: poster_path(media_file.media_item)
        }
      else
        nil
      end
    end)
    # Filter out sessions where user or media might be missing (deleted)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.user != nil))
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Records that a play started on this server.

  Sessions are the truthful signal for a play: a media-server sync writes
  playback progress without ever creating one, and counting those would report
  watches that happened on somebody else's box.

  Returns `:ok` and emits nothing when the media file has been deleted out from
  under the session, which is the same tolerance `list_active_sessions/0` has.
  """
  @spec emit_playback_started(binary(), binary()) :: :ok
  def emit_playback_started(media_file_id, user_id) do
    case Library.get_media_file(media_file_id) do
      %{episode_id: episode_id} when not is_nil(episode_id) ->
        Events.playback_event("started", user_id, [episode_id: episode_id], %{
          "origin" => "player"
        })

      %{media_item_id: media_item_id} when not is_nil(media_item_id) ->
        Events.playback_event("started", user_id, [media_item_id: media_item_id], %{
          "origin" => "player"
        })

      _ ->
        :ok
    end
  end

  @doc """
  The `Mydia.Playback` content key for a media file.

  Playback progress is keyed by episode for a TV file and by media item for a
  movie, and an episode's file carries both foreign keys (the episode, plus its
  show), so the episode clause has to come first or every TV session would look
  up the show's progress and find nothing.

  Public because it is otherwise buried inside `list_active_sessions/0`, which
  needs a live session registry to reach and so cannot be tested directly. The
  `case` it replaced could raise `CaseClauseError` from inside the function that
  renders the whole dashboard.
  """
  @spec progress_content_id(Mydia.Library.MediaFile.t()) :: keyword()
  def progress_content_id(%{episode_id: episode_id}) when not is_nil(episode_id),
    do: [episode_id: episode_id]

  # No guard on this clause, matching the behaviour it was extracted from: a
  # file with neither key yields [media_item_id: nil], which get_progress/2
  # answers with nil. Unreachable today, since list_active_sessions/0 already
  # drops files with no loaded media_item, but a crash here would be worse than
  # a missing scrubber.
  def progress_content_id(%{media_item_id: media_item_id}),
    do: [media_item_id: media_item_id]

  # An episode's media_file carries its show as media_item, so a TV session gets
  # the show poster rather than an episode still, which is what the now-playing
  # card wants.
  defp poster_path(%{metadata: %{poster_path: path}}), do: path
  defp poster_path(_), do: nil

  defp pad(num), do: String.pad_leading("#{num}", 2, "0")
end
