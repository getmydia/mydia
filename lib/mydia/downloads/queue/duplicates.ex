defmodule Mydia.Downloads.Queue.Duplicates do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Downloads.Queue.ClientSelection
  require Logger

  @doc false
  # Normalizes a SearchResult's metadata into a %SearchResultMetadata{}
  # struct. Public so the optimistic grab pipeline (Mydia.Downloads.Grabber)
  # can normalize before its own duplicate check, matching what
  # initiate_download/2 does before check_for_duplicate_download/2 — keeping
  # season-pack-aware duplicate-check guards working from both entry points.
  def normalize_search_result_metadata(%SearchResult{} = search_result) do
    %{search_result | metadata: normalize_metadata(search_result.metadata)}
  end

  # Normalizes search-result metadata into a SearchResultMetadata struct.
  # Some call sites (e.g. tv_show_search.ex) historically passed a plain
  # map, which silently bypassed every season-pack-aware guard below.
  @doc false
  def normalize_metadata(%SearchResultMetadata{} = m), do: m
  def normalize_metadata(nil), do: nil

  def normalize_metadata(%{} = m) do
    SearchResultMetadata.new(
      season_pack: m[:season_pack] || m["season_pack"],
      season_number: m[:season_number] || m["season_number"],
      episode_count: m[:episode_count] || m["episode_count"],
      episode_ids: m[:episode_ids] || m["episode_ids"]
    )
  end

  def normalize_metadata(_), do: nil

  def check_for_duplicate_download(search_result, opts) do
    media_item_id = Keyword.get(opts, :media_item_id)
    episode_id = Keyword.get(opts, :episode_id)
    manual? = Keyword.get(opts, :manual, false)

    # Always check for active downloads to prevent downloading the same thing twice
    with :ok <-
           check_for_active_download(search_result, media_item_id, episode_id,
             exclude_download_id: Keyword.get(opts, :exclude_download_id)
           ) do
      # Skip media file check for manual downloads - the user explicitly chose this release
      # (they may want to upgrade quality or grab a different version)
      if manual? do
        :ok
      else
        check_for_existing_media_files(search_result, media_item_id, episode_id)
      end
    end
  end

  def check_for_active_download(search_result, media_item_id, episode_id, opts \\ []) do
    # Query for downloads still occupying their target — actively downloading,
    # downloaded-but-awaiting-import, or import-retrying. A completed-but-not-yet
    # imported download still counts, so we don't grab a duplicate while the
    # first one is queued for import. See Mydia.Downloads.Download.occupying/1.
    base_query = Download.occupying()

    base_query =
      case Keyword.get(opts, :exclude_download_id) do
        nil -> base_query
        id -> where(base_query, [d], d.id != ^id)
      end

    # Add filters based on what we're downloading
    query =
      cond do
        # For episodes, check if there's an active download for this episode
        episode_id ->
          where(base_query, [d], d.episode_id == ^episode_id)

        # For season packs, check if there's an active download for same media_item and season
        media_item_id &&
            match?(
              %SearchResultMetadata{season_pack: true, season_number: _},
              search_result.metadata
            ) ->
          season_number = search_result.metadata.season_number

          base_query
          |> where([d], d.media_item_id == ^media_item_id)
          |> where([d], ^Mydia.DB.json_is_true(:metadata, "$.season_pack"))
          |> where(
            [d],
            ^Mydia.DB.json_integer_equals(:metadata, "$.season_number", season_number)
          )

        # Unscoped TV show request (no episode_id, not a season pack): a TV show
        # legitimately has many concurrent downloads across seasons/episodes, so
        # an active download for a *different* season/episode doesn't make THIS
        # request a duplicate. Dedupe by the exact release URL instead of by
        # media_item: different seasons have different torrent hashes (so
        # cross-season requests are allowed), while re-submitting the same
        # release (e.g. a double-clicked manual result) is still blocked.
        media_item_id && tv_show?(media_item_id) ->
          where(base_query, [d], d.download_url == ^search_result.download_url)

        # For movies or other media, check if there's an active download for this media_item
        media_item_id ->
          where(base_query, [d], d.media_item_id == ^media_item_id)

        # No media association (e.g., music, books, adult libraries)
        # Check by download_url to prevent downloading the same file twice
        true ->
          where(base_query, [d], d.download_url == ^search_result.download_url)
      end

    active_downloads = Repo.all(query)

    if active_downloads == [] do
      :ok
    else
      # Verify each "active" download still exists in the download client
      case ClientSelection.verify_downloads_in_client(active_downloads) do
        :all_stale ->
          # All were stale/orphaned - allow the new download
          :ok

        :has_active ->
          season_info =
            case search_result.metadata do
              %SearchResultMetadata{season_pack: true, season_number: sn} -> " (season #{sn})"
              _ -> ""
            end

          Logger.info("Skipping download - active download already exists#{season_info}",
            media_item_id: media_item_id,
            episode_id: episode_id
          )

          {:error, :duplicate_download}
      end
    end
  end

  defp tv_show?(media_item_id) do
    case Repo.get(MediaItem, media_item_id) do
      %MediaItem{type: "tv_show"} -> true
      _ -> false
    end
  end

  def check_for_existing_media_files(search_result, media_item_id, episode_id) do
    alias Mydia.Media.MediaItem

    cond do
      # For episodes, check if media files already exist for this episode
      episode_id ->
        query =
          from(f in MediaFile,
            where: f.episode_id == ^episode_id and is_nil(f.trashed_at) and is_nil(f.extra_kind)
          )

        if Repo.exists?(query) do
          Logger.info("Skipping download - media files already exist for episode",
            episode_id: episode_id
          )

          {:error, :already_have_files}
        else
          :ok
        end

      # A pack is grabbed to fill a specific set of episodes, so it is only
      # redundant when every one of them is already on disk. The old rule
      # rejected the pack if ANY episode in the season had a file, which made a
      # partially-complete season permanently unfillable: one stray episode
      # blocked every future pack for that season.
      media_item_id &&
          match?(
            %SearchResultMetadata{season_pack: true, season_number: _},
            search_result.metadata
          ) ->
        season_number = search_result.metadata.season_number

        targeted_ids = targeted_episode_ids(search_result.metadata, media_item_id, season_number)

        if targeted_ids != [] and all_episodes_have_files?(targeted_ids) do
          Logger.info(
            "Skipping download - every episode this season pack targets already has a file",
            media_item_id: media_item_id,
            season_number: season_number,
            targeted_episodes: length(targeted_ids)
          )

          {:error, :already_have_files}
        else
          :ok
        end

      # For media items (movies or TV shows)
      media_item_id ->
        # Get the media item to check its type
        case Repo.get(MediaItem, media_item_id) do
          %MediaItem{type: "tv_show"} ->
            # TV shows can have multiple downloads for different seasons/episodes
            # Don't block based on existing media files - the user may be downloading
            # additional seasons or complete series packs
            Logger.debug(
              "Allowing download for TV show - TV shows can have multiple season downloads",
              media_item_id: media_item_id
            )

            :ok

          %MediaItem{type: "movie"} ->
            # For movies, check if non-trashed, non-extra media files already
            # exist. An extras-only folder (a deleted scene, a featurette) must
            # not make the queue believe the movie itself is already on disk.
            query =
              from(f in MediaFile,
                where:
                  f.media_item_id == ^media_item_id and is_nil(f.trashed_at) and
                    is_nil(f.extra_kind)
              )

            if Repo.exists?(query) do
              Logger.info("Skipping download - media files already exist for movie",
                media_item_id: media_item_id
              )

              {:error, :already_have_files}
            else
              :ok
            end

          nil ->
            # Media item not found, allow download (shouldn't happen normally)
            Logger.warning("Media item not found during duplicate check",
              media_item_id: media_item_id
            )

            :ok
        end

      # No media association, can't check for existing files
      true ->
        :ok
    end
  end

  # The search records the episodes a pack was grabbed for in `episode_ids`.
  # Manual grabs and rows predating that field carry none, so fall back to the
  # season's full episode list, which makes the rule "block only if the whole
  # season is already on disk".
  defp targeted_episode_ids(%SearchResultMetadata{episode_ids: ids}, _media_item_id, _season)
       when is_list(ids) and ids != [],
       do: ids

  defp targeted_episode_ids(_metadata, media_item_id, season_number) do
    Repo.all(
      from(e in Episode,
        where: e.media_item_id == ^media_item_id and e.season_number == ^season_number,
        select: e.id
      )
    )
  end

  defp all_episodes_have_files?(episode_ids) do
    wanted = episode_ids |> Enum.uniq() |> length()

    filed =
      Repo.one(
        from(f in MediaFile,
          where: f.episode_id in ^episode_ids and is_nil(f.trashed_at) and is_nil(f.extra_kind),
          select: count(f.episode_id, :distinct)
        )
      )

    filed == wanted
  end
end
