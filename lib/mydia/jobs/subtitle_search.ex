defmodule Mydia.Jobs.SubtitleSearch do
  @moduledoc """
  Fills in missing subtitle languages for every file in one season.

  The per-file modal covers a single episode; this exists because a
  twenty-four episode season is otherwise twenty-four trips through it.

  Files are processed one at a time on purpose. The provider chain already
  survives a single provider failing, and sequential execution meets provider
  rate limits as spaced requests rather than a burst of twenty-four.

  A file is only searched for the languages it actually lacks. Embedded and
  sidecar tracks count as present, so a release that ships English inside the
  container is never searched for English.
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  import Ecto.Query

  require Logger

  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Subtitles

  @topic "subtitles"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "season"} = args}) do
    %{"media_item_id" => media_item_id, "season_number" => season_number} = args

    wanted = Mydia.Settings.get_config([:streaming, :subtitle_language], ["en"])

    media_item_id
    |> season_media_files(season_number)
    |> Enum.each(&process_file(&1, wanted))

    broadcast({:subtitle_season_finished, media_item_id, season_number})

    :ok
  end

  @doc """
  The wanted languages a file does not already have, in the order they were
  wanted. Every track counts regardless of origin.
  """
  @spec missing_languages([map()], [String.t()]) :: [String.t()]
  def missing_languages(tracks, wanted) do
    present = MapSet.new(tracks, & &1.language)

    Enum.reject(wanted, &MapSet.member?(present, &1))
  end

  # Every non-trashed media file belonging to the season's episodes, with
  # :library_path preloaded (the downloader resolves the real path from it)
  # and :metadata loaded (list_subtitle_tracks/1 reads metadata.streams and
  # only shells out to ffprobe when it is absent - a fallback that must not
  # fire for a whole season).
  defp season_media_files(media_item_id, season_number) do
    active_files_query =
      from(mf in MediaFile, where: is_nil(mf.trashed_at), preload: :library_path)

    media_item_id
    |> Media.list_episodes(season: season_number, preload: [media_files: active_files_query])
    |> Enum.flat_map(& &1.media_files)
  end

  defp process_file(media_file, wanted) do
    tracks = Subtitles.Extractor.list_subtitle_tracks(media_file)

    case missing_languages(tracks, wanted) do
      [] ->
        :ok

      missing ->
        search(media_file, missing)
        broadcast({:subtitles_updated, media_file.id})
    end
  end

  # One file failing must not abort the season, so the result is logged and
  # discarded rather than propagated.
  defp search(media_file, missing) do
    case Subtitles.search_subtitles(media_file.id,
           languages: Enum.join(missing, ","),
           auto_download: true
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Season subtitle search failed for one file",
          media_file_id: media_file.id,
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.error("Season subtitle search raised",
        media_file_id: media_file.id,
        error: Exception.message(error)
      )

      :ok
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Mydia.PubSub, @topic, message)
  end
end
