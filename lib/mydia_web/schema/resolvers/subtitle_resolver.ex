defmodule MydiaWeb.Schema.Resolvers.SubtitleResolver do
  @moduledoc """
  Resolvers for subtitle-related GraphQL fields.
  """

  alias Mydia.Library
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Extractor

  require Logger

  @doc """
  Lists all available subtitle tracks for a media file.

  Returns both embedded subtitles (from the media file) and external subtitle files.
  """
  def list_subtitles(%{id: media_file_id} = media_file, _args, _info) do
    # Ensure library_path is preloaded
    media_file =
      if Ecto.assoc_loaded?(media_file.library_path) do
        media_file
      else
        Library.get_media_file!(media_file_id, preload: [:library_path])
      end

    tracks = Extractor.list_subtitle_tracks(media_file)

    # Add the media_file_id to each track so the URL resolver can access it
    tracks_with_metadata =
      Enum.map(tracks, fn track ->
        track
        |> Map.put(:_media_file_id, media_file_id)
        |> normalize_track_id()
      end)

    {:ok, tracks_with_metadata}
  rescue
    Ecto.NoResultsError ->
      {:ok, []}

    e ->
      Logger.error("Failed to list subtitles: #{inspect(e)}")
      {:ok, []}
  end

  @doc """
  Resolves a subtitle track's body, converted to the requested format.
  """
  def content(track, args, _info) do
    media_file_id = Map.get(track, :_media_file_id)
    format = Atom.to_string(args[:format] || :vtt)

    cond do
      is_nil(media_file_id) ->
        {:ok, nil}

      not Map.get(track, :deliverable, true) ->
        {:ok, nil}

      true ->
        media_file = Library.get_media_file!(media_file_id, preload: [:library_path])

        case Delivery.content(media_file, denormalize_track_id(track.track_id), format) do
          {:ok, body} ->
            {:ok, body}

          {:error, reason} ->
            Logger.warning("Subtitle content unavailable",
              media_file_id: media_file_id,
              track_id: track.track_id,
              reason: inspect(reason)
            )

            {:ok, nil}
        end
    end
  rescue
    Ecto.NoResultsError -> {:ok, nil}
  end

  @doc """
  Resolves a single subtitle track's body from a media file id and track id
  directly, without resolving any other track on the file.

  `movie(id) { files { subtitles { content } } }` cannot express "give me
  just this one track": Absinthe resolves `content` for every track of every
  file the query selects. This root field takes the media file id and track
  id together (there is no root `mediaFile(id:)` query and `MediaFile` does
  not implement `Node`) so a client can fetch exactly one body.
  """
  def subtitle_content(_root, %{media_file_id: media_file_id, track_id: track_id} = args, _info) do
    format = Atom.to_string(args[:format] || :vtt)
    media_file = Library.get_media_file!(media_file_id, preload: [:library_path])

    track =
      media_file
      |> Extractor.list_subtitle_tracks()
      |> Enum.find(&(to_string(&1.track_id) == track_id))

    cond do
      is_nil(track) ->
        {:ok, nil}

      not Map.get(track, :deliverable, true) ->
        {:ok, nil}

      true ->
        case Delivery.content(media_file, denormalize_track_id(track_id), format) do
          {:ok, body} ->
            {:ok, body}

          {:error, reason} ->
            Logger.warning("Subtitle content unavailable",
              media_file_id: media_file_id,
              track_id: track_id,
              reason: inspect(reason)
            )

            {:ok, nil}
        end
    end
  rescue
    Ecto.NoResultsError -> {:ok, nil}
  end

  # Normalize track_id to always be a string for consistency
  defp normalize_track_id(%{track_id: track_id} = track) when is_integer(track_id) do
    %{track | track_id: Integer.to_string(track_id)}
  end

  defp normalize_track_id(track), do: track

  # `list_subtitles/3` stringifies track ids for the wire. Delivery needs the
  # integer back for embedded tracks so it selects the right ffmpeg stream.
  defp denormalize_track_id(track_id) when is_binary(track_id) do
    case Integer.parse(track_id) do
      {int, ""} -> int
      _ -> track_id
    end
  end

  defp denormalize_track_id(track_id), do: track_id
end
