defmodule Mydia.Downloads.Queue do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Mydia.Repo
  alias Mydia.Downloads.ContentType
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.History
  alias Mydia.Downloads.Priority
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Mydia.Downloads.Structs.ExternalTorrent
  alias Mydia.Downloads.TorrentHash
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata
  alias Mydia.Settings
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Events
  require Logger

  ## Public Functions

  @doc """
  Drops episodes already covered by an active season-pack download.

  A season-pack download carries `media_item_id` plus `metadata.season_pack`
  and **no** `episode_id`, so any query that excludes on `episode_id` alone
  cannot see it - including the `check_for_active_download/4` episode arm
  below, which is why an individual grab for an episode inside an in-flight
  pack succeeds. Both the missing-file search path
  (`Mydia.Jobs.TVShowSearch`) and the upgrade eligibility query
  (`Mydia.Upgrades.eligible_episodes/1`) filter through here so the two cannot
  drift apart.

  Matched by `{media_item_id, season_number}` on downloads that are still
  occupying their target (see `Mydia.Downloads.Download.occupying/1`).
  """
  @spec reject_episodes_in_active_season_packs([Episode.t()]) :: [Episode.t()]
  def reject_episodes_in_active_season_packs([]), do: []

  def reject_episodes_in_active_season_packs(episodes) when is_list(episodes) do
    media_item_ids =
      episodes
      |> Enum.map(& &1.media_item_id)
      |> Enum.uniq()

    covered =
      Download.occupying()
      |> where([d], d.media_item_id in ^media_item_ids)
      |> where(^Mydia.DB.json_is_true(:metadata, "$.season_pack"))
      |> select([d], %{media_item_id: d.media_item_id, metadata: d.metadata})
      |> Repo.all()
      |> Enum.reduce(MapSet.new(), fn
        %{media_item_id: mid, metadata: %{"season_number" => sn}}, acc when is_integer(sn) ->
          MapSet.put(acc, {mid, sn})

        _, acc ->
          acc
      end)

    Enum.reject(episodes, fn episode ->
      MapSet.member?(covered, {episode.media_item_id, episode.season_number})
    end)
  end

  def initiate_download(%SearchResult{} = search_result, opts \\ []) do
    # Normalize metadata: callers (e.g. TVShowSearch) may pass a plain map.
    # Coerce to %SearchResultMetadata{} so downstream pattern matches and
    # persistence in create_download_record/4 work uniformly.
    search_result = normalize_search_result_metadata(search_result)

    # Use protocol from search result
    download_type = search_result.download_protocol
    Logger.debug("Download protocol: #{inspect(download_type)} for #{search_result.title}")

    opts = Keyword.put(opts, :download_type, download_type)

    with :ok <- check_for_duplicate_download(search_result, opts),
         {:ok, client_config, client_id, detected_type} <-
           select_and_add_to_client(search_result, opts),
         {:ok, download} <-
           create_download_record_with_retry(search_result, client_config, client_id, opts) do
      # Use detected type as fallback if protocol wasn't set
      final_type = download_type || detected_type

      Logger.info(
        "Final download type: #{inspect(final_type)} (original: #{inspect(download_type)}, detected: #{inspect(detected_type)})"
      )

      # Track event
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "downloads_context")

      # Get media_item for context if available (preloaded on download)
      download_with_media = Repo.preload(download, :media_item)

      Events.download_initiated(download_with_media, actor_type, actor_id,
        media_item: download_with_media.media_item
      )

      {:ok, download}
    else
      {:error, reason} = error ->
        Logger.warning("Failed to initiate download: #{inspect(reason)}")
        error
    end
  end

  def cancel_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config),
         client_map_config = config_to_map(client_config),
         :ok <-
           Client.remove_download(adapter, client_map_config, download.download_client_id, opts),
         {:ok, _deleted} <- History.delete_download(download) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_cancelled(download, actor_type, actor_id)

      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to cancel download: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Rejects a release the operator has judged unusable.

  Blacklists `(indexer, guid)` so future searches filter it out, removes the
  torrent and its data from the client, deletes the download row, and queues a
  fresh search for the bound episode or movie.

  The blacklist write happens first: if a later step fails, the release must
  still not be re-grabbed. Client removal is best effort, since the torrent may
  already be gone.

  Accepts `:failure_reason` (default `"rejected_by_user"`) so a system-initiated
  rejection is distinguishable from an operator's in `release_blacklist`.
  """
  @spec reject_release(Download.t(), keyword()) ::
          {:ok, :rejected} | {:error, :no_indexer | :no_guid | term()}
  def reject_release(%Download{} = download, opts \\ []) do
    with {:ok, indexer, guid} <- Blacklists.extract_key(download),
         {:ok, _row} <-
           Blacklists.add(
             indexer,
             guid,
             download.title || "Unknown release",
             Keyword.get(opts, :failure_reason, "rejected_by_user")
           ) do
      # Computed before deletion: it reads through the media_item association.
      search = replacement_search(download)

      remove_from_client(download)

      case History.delete_download(download) do
        {:ok, _deleted} ->
          enqueue_search(search)

          Events.download_cancelled(
            download,
            Keyword.get(opts, :actor_type, :user),
            Keyword.get(opts, :actor_id, "unknown")
          )

          {:ok, :rejected}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def pause_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config),
         client_map_config = config_to_map(client_config),
         :ok <- Client.pause_torrent(adapter, client_map_config, download.download_client_id) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_paused(download, actor_type, actor_id)

      History.broadcast_download_update(download.id)
      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to pause download in client: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def resume_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config),
         client_map_config = config_to_map(client_config),
         :ok <- Client.resume_torrent(adapter, client_map_config, download.download_client_id) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_resumed(download, actor_type, actor_id)

      History.broadcast_download_update(download.id)
      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to resume download in client: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def clear_completed(%Download{} = download, opts \\ []) do
    # Try to remove from client first (ignore errors as may already be removed)
    case find_client_config(download.download_client) do
      {:ok, client_config} ->
        case get_adapter_for_client(client_config) do
          {:ok, adapter} ->
            client_map_config = config_to_map(client_config)

            # Attempt to remove from client, but don't fail if it's already gone
            case Client.remove_download(
                   adapter,
                   client_map_config,
                   download.download_client_id,
                   opts
                 ) do
              :ok ->
                Logger.info("Removed completed download from client",
                  download_id: download.id,
                  client: download.download_client
                )

              {:error, reason} ->
                Logger.debug("Could not remove from client (may already be removed)",
                  download_id: download.id,
                  reason: inspect(reason)
                )
            end

          {:error, _} ->
            Logger.debug("No adapter found for client", client: download.download_client)
        end

      {:error, _} ->
        Logger.debug("Client config not found", client: download.download_client)
    end

    # Always delete the database record
    case History.delete_download(download) do
      {:ok, deleted_download} ->
        # Track event
        actor_type = Keyword.get(opts, :actor_type, :user)
        actor_id = Keyword.get(opts, :actor_id, "unknown")

        Events.download_cleared(download, actor_type, actor_id)

        {:ok, deleted_download}

      error ->
        error
    end
  end

  def clear_all_completed(opts \\ []) do
    # Get all imported downloads
    imported_downloads =
      Download
      |> where([d], not is_nil(d.imported_at))
      |> Repo.all()

    results =
      Enum.map(imported_downloads, fn download ->
        case clear_completed(download, opts) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    {:ok, success_count}
  end

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
  defp normalize_metadata(%SearchResultMetadata{} = m), do: m
  defp normalize_metadata(nil), do: nil

  defp normalize_metadata(%{} = m) do
    SearchResultMetadata.new(
      season_pack: m[:season_pack] || m["season_pack"],
      season_number: m[:season_number] || m["season_number"],
      episode_count: m[:episode_count] || m["episode_count"],
      episode_ids: m[:episode_ids] || m["episode_ids"]
    )
  end

  defp normalize_metadata(_), do: nil

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
      case verify_downloads_in_client(active_downloads) do
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
        query = from(f in MediaFile, where: f.episode_id == ^episode_id and is_nil(f.trashed_at))

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
            # For movies, check if non-trashed media files already exist
            query =
              from(f in MediaFile,
                where: f.media_item_id == ^media_item_id and is_nil(f.trashed_at)
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
          where: f.episode_id in ^episode_ids and is_nil(f.trashed_at),
          select: count(f.episode_id, :distinct)
        )
      )

    filed == wanted
  end

  # --- Issues Tab Functions ---

  def manually_match_download(%Download{} = download, media_item_id, episode_id \\ nil) do
    save_path = get_in(download.metadata || %{}, ["save_path"])

    # Keep match_status until import succeeds (import job clears it)
    attrs = %{
      media_item_id: media_item_id,
      episode_id: episode_id
    }

    case History.update_download(download, attrs) do
      {:ok, updated} ->
        job_result =
          %{
            "download_id" => updated.id,
            "save_path" => save_path,
            "cleanup_client" => true,
            "use_hardlinks" => true,
            "move_files" => false
          }
          |> Mydia.Jobs.MediaImport.new()
          |> insert_job()

        case job_result do
          {:ok, _job} -> {:ok, updated}
          {:error, _changeset} = error -> error
        end

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Creates a tracked download for a foreign client torrent and queues its import.

  Foreign torrents are derived and have no database row, so matching one is a
  create rather than an update. The row is written with `match_status: nil`,
  which is exactly what a normally-grabbed download looks like, so everything
  downstream treats it as ordinary work instead of a special case.

  Returns `{:error, :already_tracked}` when the unique
  `(download_client, download_client_id)` pair is taken, which is what a second
  browser tab adopting the same torrent hits.
  """
  @spec adopt_external_torrent(ExternalTorrent.t(), binary(), binary() | nil) ::
          {:ok, Download.t()} | {:error, :already_tracked} | {:error, Ecto.Changeset.t()}
  def adopt_external_torrent(%ExternalTorrent{} = torrent, media_item_id, episode_id \\ nil) do
    attrs = %{
      indexer: "manual",
      title: torrent.title,
      download_url: nil,
      download_client: torrent.client_name,
      download_client_id: torrent.client_id,
      media_item_id: media_item_id,
      episode_id: episode_id,
      metadata: %{
        size: torrent.size,
        save_path: torrent.save_path,
        matched_from_client: true
      }
    }

    with {:ok, download} <- create_adopted_download(attrs),
         {:ok, _job} <- enqueue_adopted_import(download, torrent.save_path) do
      {:ok, download}
    end
  end

  defp create_adopted_download(attrs) do
    case History.create_download(attrs) do
      {:ok, download} ->
        {:ok, download}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :download_client) do
          {:error, :already_tracked}
        else
          error
        end
    end
  end

  defp enqueue_adopted_import(download, save_path) do
    %{
      "download_id" => download.id,
      "save_path" => save_path,
      "cleanup_client" => true,
      "use_hardlinks" => true,
      "move_files" => false
    }
    |> Mydia.Jobs.MediaImport.new()
    |> insert_job()
  end

  def resolve_file_mappings(%Download{} = download, mappings) when is_list(mappings) do
    # Build target_files for the MediaImport job (mappings always use string keys)
    target_files =
      Enum.map(mappings, fn mapping ->
        %{
          "path" => mapping["path"],
          "episode_id" => mapping["episode_id"]
        }
      end)

    # Don't clear match_status or unresolved_files metadata here — the import job
    # clears them on success. This preserves data for retry if import fails.
    case %{
           "download_id" => download.id,
           "target_files" => target_files,
           "use_hardlinks" => true,
           "move_files" => false
         }
         |> Mydia.Jobs.MediaImport.new()
         |> insert_job() do
      {:ok, _job} -> {:ok, download}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Re-matches an already-imported download to a corrected movie or episode.

  Validates lifecycle, scope, and library-type compatibility before any mutation,
  then enqueues `Mydia.Jobs.MediaRematch` to move + relink the file. Single-target
  only: a download whose provenance resolves to multiple imported files (a pack)
  is refused.

  Returns:
    * `{:ok, :enqueued}` — a re-match job was scheduled
    * `{:ok, :unchanged}` — the target already matches; nothing to do
    * `{:error, :not_imported}` — not imported yet (use in-flight correction)
    * `{:error, :not_single_target}` — partial_pack / unresolved_files / unmatched
    * `{:error, :multiple_files}` — pack: per-file re-match not supported
    * `{:error, :no_imported_file}` — could not locate the imported file
    * `{:error, :no_library_path}` — no monitored, compatible destination library
    * `{:error, :library_type_mismatch}` — target type incompatible with library
  """
  def rematch_imported_download(%Download{} = download, media_item_id, episode_id \\ nil) do
    cond do
      is_nil(download.imported_at) ->
        {:error, :not_imported}

      not is_nil(download.match_status) ->
        {:error, :not_single_target}

      download.media_item_id == media_item_id and download.episode_id == episode_id ->
        {:ok, :unchanged}

      true ->
        do_rematch(download, media_item_id, episode_id)
    end
  end

  defp do_rematch(download, media_item_id, episode_id) do
    media_item = media_item_id && Repo.get(MediaItem, media_item_id)
    episode = episode_id && Repo.get(Episode, episode_id)

    with {:ok, _file} <- locate_single_imported_file(download),
         {:ok, library_path} <- resolve_rematch_destination(media_item, episode),
         :ok <- ensure_type_compatible(library_path, media_item, episode_id) do
      case History.update_download(download, %{
             media_item_id: media_item_id,
             episode_id: episode_id
           }) do
        {:ok, updated} ->
          case %{"download_id" => updated.id}
               |> Mydia.Jobs.MediaRematch.new()
               |> insert_job() do
            {:ok, _job} -> {:ok, :enqueued}
            {:error, _changeset} = error -> error
          end

        {:error, _changeset} = error ->
          error
      end
    end
  end

  # Insert an Oban job, falling back to a direct Repo insert when Oban's engine
  # is disabled (test mode). Mirrors the pattern in DownloadMonitor.
  defp insert_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end

  defp locate_single_imported_file(download) do
    case Mydia.Library.list_media_files_for_download(download) do
      [%MediaFile{} = file] -> {:ok, file}
      [] -> {:error, :no_imported_file}
      _multiple -> {:error, :multiple_files}
    end
  end

  defp resolve_rematch_destination(media_item, episode) do
    # Resolves against the NEW target: the download row still holds the old one
    # here, so no download is passed and step 1 is skipped by design.
    _ = episode

    case media_item && Mydia.Library.TargetResolver.resolve(media_item) do
      {:ok, library_path, _reason} -> {:ok, library_path}
      _ -> {:error, :no_library_path}
    end
  end

  defp ensure_type_compatible(library_path, media_item, episode_id) do
    media_item_type = media_item && media_item.type

    if MediaFile.library_type_compatible?(
         library_path.type,
         media_item_type,
         not is_nil(episode_id)
       ) do
      :ok
    else
      {:error, :library_type_mismatch}
    end
  end

  def dismiss_download(%Download{} = download) do
    History.delete_download(download)
  end

  def dismiss_all_cancelled do
    from(d in Download,
      where:
        is_nil(d.match_status) and is_nil(d.imported_at) and
          (not is_nil(d.error_message) or not is_nil(d.import_failed_at))
    )
    |> Repo.delete_all()
  end

  # Best effort: a torrent the client no longer holds must not block the reject.
  defp remove_from_client(%Download{download_client: nil}), do: :ok
  defp remove_from_client(%Download{download_client_id: nil}), do: :ok

  defp remove_from_client(download) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      Client.remove_download(
        adapter,
        config_to_map(client_config),
        download.download_client_id,
        delete_files: true
      )
    end

    :ok
  rescue
    exception ->
      Logger.warning("Could not remove rejected release from client",
        download_id: download.id,
        error: Exception.message(exception)
      )

      :ok
  catch
    # The debrid adapter's remove_torrent/3 terminates any running Fetcher
    # first via DynamicSupervisor.terminate_child/2 — a GenServer.call that
    # emits an :exit signal (not an Elixir exception) if the supervisor isn't
    # alive, same hazard documented on
    # Mydia.Downloads.Client.Debrid.RateLimiter.acquire/3. `rescue` alone
    # would not catch it, and a client that will not answer must not block
    # rejecting a bad release.
    :exit, reason ->
      Logger.warning("Could not remove rejected release from client (process exit)",
        download_id: download.id,
        reason: inspect(reason)
      )

      :ok
  end

  # Returns an Oban changeset, or nil when there is nothing sensible to search
  # for. `Media` exposes only the raising `get_media_item!/1`, so this reads the
  # association instead: a deleted media item yields nil rather than raising in
  # the middle of a cleanup path.
  defp replacement_search(%Download{episode_id: episode_id}) when is_binary(episode_id) do
    Mydia.Jobs.TVShowSearch.new(%{"mode" => "specific", "episode_id" => episode_id})
  end

  defp replacement_search(%Download{media_item_id: media_item_id} = download)
       when is_binary(media_item_id) do
    case Repo.preload(download, :media_item).media_item do
      %{type: "movie", id: id} ->
        Mydia.Jobs.MovieSearch.new(%{"mode" => "specific", "media_item_id" => id})

      %{type: "tv_show", id: id} ->
        Mydia.Jobs.TVShowSearch.new(%{"mode" => "show", "media_item_id" => id})

      _other ->
        nil
    end
  end

  defp replacement_search(_download), do: nil

  defp enqueue_search(nil), do: :ok
  defp enqueue_search(changeset), do: insert_job(changeset)

  ## Private Functions - Download Initiation

  defp verify_downloads_in_client(downloads) do
    has_active =
      Enum.any?(downloads, fn download ->
        case verify_single_download_in_client(download) do
          :active -> true
          :stale -> false
        end
      end)

    if has_active, do: :has_active, else: :all_stale
  end

  defp verify_single_download_in_client(download) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      client_map_config = config_to_map(client_config)

      case Client.get_status(adapter, client_map_config, download.download_client_id) do
        {:ok, _status} ->
          :active

        {:error, %{type: :not_found}} ->
          Logger.warning("Active download not found in client, marking as failed",
            download_id: download.id,
            title: download.title,
            client: download.download_client
          )

          History.mark_download_failed(download, "Torrent no longer exists in download client")
          :stale

        {:error, reason} ->
          # Client error (connection issue, etc.) - assume download is still active
          # to avoid accidentally re-downloading
          Logger.warning("Could not verify download in client, assuming active",
            download_id: download.id,
            reason: inspect(reason)
          )

          :active
      end
    else
      {:error, _reason} ->
        # Client config not found - can't verify, assume active
        :active
    end
  end

  @doc false
  # Resolves a client name to {adapter, config_map}. Public so callers outside
  # this module (Mydia.Jobs.DownloadMonitor) can talk to a download client
  # without duplicating the config lookup, adapter lookup and config_to_map
  # conversion for a sixth time.
  @spec resolve_adapter(String.t() | nil) :: {:ok, module(), map()} | {:error, term()}
  def resolve_adapter(nil), do: {:error, :no_client}

  def resolve_adapter(client_name) do
    with {:ok, client_config} <- find_client_config(client_name),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      {:ok, adapter, config_to_map(client_config)}
    end
  end

  # Selects appropriate client and adds the download, with smart fallback if type is detected
  @doc false
  # Public so Mydia.Downloads.Grabber can reuse the fetch/select/add pipeline.
  def select_and_add_to_client(search_result, opts) do
    download_type = Keyword.get(opts, :download_type)

    # First, prepare the torrent/nzb input (download file if needed)
    # Pass the indexer name for authentication
    with {:ok, torrent_input_result} <-
           prepare_torrent_input(search_result.download_url, search_result.indexer) do
      # Extract detected type from the downloaded content
      detected_type =
        case torrent_input_result do
          {:file, _body, type} -> type
          _ -> nil
        end

      # Use detected type as fallback if download_type is nil
      final_download_type = download_type || detected_type

      Logger.info(
        "File type detection: original=#{inspect(download_type)}, detected=#{inspect(detected_type)}, final=#{inspect(final_download_type)}"
      )

      # Resolve a content type (e.g. "tv", "movie") so per-content-type
      # routing in the client config can pick the right category. See
      # `resolve_content_type/1` for the precedence rules.
      content_type = resolve_content_type(opts)

      # Update opts with the final download type and title
      opts_with_type =
        opts
        |> Keyword.put(:download_type, final_download_type)
        |> Keyword.put(:title, search_result.title)
        |> Keyword.put(:content_type, content_type)

      # Now select the appropriate client based on the final type
      with {:ok, client_config} <- select_download_client(opts_with_type),
           {:ok, adapter} <- get_adapter_for_client(client_config) do
        # Extract the actual torrent input (without the type)
        torrent_input =
          case torrent_input_result do
            {:file, body, _type} -> {:file, body}
            other -> other
          end

        # Add to the selected client
        case add_torrent_to_client_with_input(
               adapter,
               client_config,
               torrent_input,
               opts_with_type
             ) do
          {:ok, client_id} ->
            {:ok, client_config, client_id, final_download_type}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  # Version of add_torrent_to_client that accepts pre-downloaded input
  defp add_torrent_to_client_with_input(adapter, client_config, torrent_input, opts) do
    client_map_config = config_to_map(client_config)
    content_type = Keyword.get(opts, :content_type)
    category = resolve_category(client_config, content_type, opts)
    title = Keyword.get(opts, :title)
    priority = Keyword.get(opts, :priority, Priority.default())

    torrent_opts =
      []
      |> maybe_add_opt(:category, category)
      |> maybe_add_opt(:title, title)
      |> maybe_add_opt(:priority, priority)

    case Client.add_torrent(adapter, client_map_config, torrent_input, torrent_opts) do
      {:ok, client_id} ->
        {:ok, client_id}

      {:error, error} ->
        {:error, {:client_error, error}}
    end
  end

  @doc false
  # Resolves the per-content-type category from the client config, falling back
  # to the legacy single-value `:category` field for backwards compatibility.
  # Order of precedence:
  #   1. explicit `opts[:category]` (manual override, rare)
  #   2. `client_config.categories[content_type]`
  #   3. `client_config.category` (legacy field)
  #   4. nil
  # Public-but-undocumented so tests can exercise it without round-tripping
  # through `initiate_download/2`.
  def resolve_category(client_config, content_type, opts) do
    cond do
      Keyword.has_key?(opts, :category) ->
        Keyword.get(opts, :category)

      is_binary(content_type) ->
        categories = client_config.categories || %{}

        case Map.get(categories, content_type) do
          nil -> client_config.category
          "" -> client_config.category
          value -> value
        end

      true ->
        client_config.category
    end
  end

  @doc false
  # Derives a content_type string from the download options + media context.
  # Centralised here so new content types (e.g. "music") can be added in one
  # place. Returns a string ("tv", "movie") or nil when the type cannot be
  # determined from the available context.
  # Public-but-undocumented for testability.
  def resolve_content_type(opts) do
    cond do
      Keyword.get(opts, :episode_id) ->
        "tv"

      media_item_id = Keyword.get(opts, :media_item_id) ->
        case Repo.get(MediaItem, media_item_id) do
          %MediaItem{type: "movie"} -> "movie"
          %MediaItem{type: "tv_show"} -> "tv"
          _ -> content_type_from_download_type(Keyword.get(opts, :download_type))
        end

      true ->
        content_type_from_download_type(Keyword.get(opts, :download_type))
    end
  end

  # Best-effort fallback when we can't resolve from media_item / episode.
  # Returns nil when the protocol gives us nothing useful, so the caller will
  # fall back to the legacy single `category` field via `resolve_category/3`.
  defp content_type_from_download_type(_), do: nil

  defp select_download_client(opts) do
    client_name = Keyword.get(opts, :client_name)
    download_type = Keyword.get(opts, :download_type)

    # Use specific client if requested
    if client_name do
      case find_client_by_name(client_name) do
        nil -> {:error, {:client_not_found, client_name}}
        client -> {:ok, client}
      end
    else
      # Otherwise select by priority, filtered by download type
      case select_client_by_priority(download_type) do
        nil -> {:error, :no_clients_configured}
        client -> {:ok, client}
      end
    end
  end

  defp find_client_by_name(name) do
    Settings.list_download_client_configs()
    |> Enum.find(&(&1.name == name && &1.enabled))
  end

  defp select_client_by_priority(download_type) do
    client =
      Settings.list_download_client_configs()
      |> Enum.filter(&(&1.enabled and supports_download_type?(&1, download_type)))
      |> Enum.sort_by(& &1.priority, :asc)
      |> List.first()

    if client do
      Logger.info(
        "Selected download client: #{client.name} (type: #{client.type}, priority: #{client.priority}) for download_type: #{download_type}"
      )
    else
      Logger.warning("No suitable client found for download_type: #{download_type}")
    end

    client
  end

  # Public-but-undocumented for testability.
  #
  # Asks the adapter what protocols it accepts and matches against the
  # search result's resolved download_type. When download_type is nil (we
  # couldn't sniff it from the payload), every client is eligible — the
  # adapter's `add_torrent/3` will reject mismatched payloads.
  def supports_download_type?(_client, nil), do: true

  def supports_download_type?(client, download_type) do
    case Registry.get_adapter(client.type) do
      {:ok, adapter} ->
        # `function_exported?/3` returns false for modules that haven't been
        # loaded yet (it doesn't auto-load). In production every adapter is
        # loaded during application boot via Mydia.Downloads.register_clients/0,
        # but in tests modules load lazily and the check would falsely
        # report "not supported". `Code.ensure_loaded?/1` forces a load
        # before the predicate runs.
        Code.ensure_loaded?(adapter) and
          function_exported?(adapter, :supported_protocols, 0) and
          download_type in adapter.supported_protocols()

      {:error, _} ->
        false
    end
  end

  defp get_adapter_for_client(client_config) do
    case Registry.get_adapter(client_config.type) do
      {:ok, adapter} ->
        Logger.info("Using adapter #{inspect(adapter)} for client type #{client_config.type}")
        {:ok, adapter}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # Builds the metadata map persisted on a Download for a search result.
  # Public so the optimistic grab pipeline (Mydia.Downloads.Grabber) can build
  # identical records without going through the synchronous pipeline.
  def build_download_metadata(%SearchResult{} = search_result) do
    search_result = %{search_result | metadata: normalize_metadata(search_result.metadata)}

    metadata_attrs = %{
      size: search_result.size,
      seeders: search_result.seeders,
      leechers: search_result.leechers,
      quality: search_result.quality,
      download_protocol: search_result.download_protocol
    }

    metadata_attrs =
      case search_result.metadata do
        %SearchResultMetadata{season_pack: true, season_number: season_number} = m ->
          Map.merge(metadata_attrs, %{
            season_pack: true,
            season_number: season_number,
            episode_count: m.episode_count,
            episode_ids: m.episode_ids
          })

        _ ->
          metadata_attrs
      end

    metadata_attrs
    |> DownloadMetadata.new()
    |> DownloadMetadata.to_map()
    |> Map.put(:indexer, search_result.indexer)
    |> Map.put(:guid, search_result.guid || fallback_release_guid(search_result))
  end

  defp create_download_record(search_result, client_config, client_id, opts) do
    metadata = build_download_metadata(search_result)

    attrs = %{
      indexer: search_result.indexer,
      title: search_result.title,
      download_url: search_result.download_url,
      download_client: client_config.name,
      download_client_id: client_id,
      media_item_id: Keyword.get(opts, :media_item_id),
      episode_id: Keyword.get(opts, :episode_id),
      library_path_id: Keyword.get(opts, :library_path_id),
      metadata: metadata
    }

    History.create_download(attrs)
  end

  # Synthesizes a stable fallback identifier when the indexer didn't provide
  # a `guid`. SHA-256 of `(indexer, title, size)` is deterministic across
  # processes so the same release hashes to the same key — good enough for
  # blacklist dedup.
  defp fallback_release_guid(%SearchResult{} = sr) do
    parts = [sr.indexer || "", sr.title || "", to_string(sr.size || 0)]
    payload = Enum.join(parts, "|")

    "sha256:" <>
      (:crypto.hash(:sha256, payload) |> Base.encode16(case: :lower))
  end

  defp create_download_record_with_retry(search_result, client_config, client_id, opts) do
    case create_download_record(search_result, client_config, client_id, opts) do
      {:ok, download} ->
        {:ok, download}

      {:error, %Ecto.Changeset{} = changeset}
      when is_struct(changeset, Ecto.Changeset) ->
        if has_unique_constraint_error?(changeset, :download_client) do
          Logger.warning(
            "Unique constraint on download_client_id, cleaning stale record and retrying",
            client: client_config.name,
            client_id: client_id
          )

          case find_stale_download(client_config.name, client_id) do
            nil ->
              {:error, changeset}

            stale_download ->
              Logger.info("Deleting stale download record",
                download_id: stale_download.id,
                title: stale_download.title
              )

              History.delete_download(stale_download)
              create_download_record(search_result, client_config, client_id, opts)
          end
        else
          {:error, changeset}
        end

      error ->
        error
    end
  end

  defp has_unique_constraint_error?(%Ecto.Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp find_stale_download(client_name, client_id) do
    Download
    |> where([d], d.download_client == ^client_name and d.download_client_id == ^client_id)
    |> Repo.one()
  end

  defp find_client_config(client_name) do
    case find_client_by_name(client_name) do
      nil -> {:error, {:client_not_found, client_name}}
      client -> {:ok, client}
    end
  end

  defp config_to_map(config) do
    %{
      type: config.type,
      host: config.host,
      port: config.port,
      use_ssl: config.use_ssl,
      username: config.username,
      password: config.password,
      url_base: config.url_base,
      api_key: config.api_key,
      connection_settings: config.connection_settings || %{},
      options: config.connection_settings || %{},
      # Surfaced for adapters that need per-client policy (priority routing,
      # per-content-type categories, stall grace). Adapters that don't care
      # about these fields simply ignore them.
      categories: Map.get(config, :categories) || %{},
      priority_profile: Map.get(config, :priority_profile) || %{},
      incomplete_grace_minutes: Map.get(config, :incomplete_grace_minutes)
    }
  end

  defp prepare_torrent_input(url, indexer_name) do
    result =
      cond do
        # Magnet links can be used directly
        String.starts_with?(url, "magnet:") ->
          {:ok, {:magnet, url}}

        # For HTTP(S) URLs, download the torrent file content
        # This avoids redirect issues that download clients can't handle
        String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
          download_torrent_file(url, indexer_name)

        # Unknown format, try as URL
        true ->
          {:ok, {:url, url}}
      end

    # Every magnet-producing path funnels back through here: the direct link
    # above, a redirect to a magnet, a response body that *is* a magnet, and a
    # magnet scraped out of an HTML page. Enriching once at the exit keeps a
    # trackerless magnet from reaching the client with DHT as its only peer
    # source. See `TorrentHash.ensure_trackers/1`.
    case result do
      {:ok, {:magnet, magnet}} -> {:ok, {:magnet, TorrentHash.ensure_trackers(magnet)}}
      other -> other
    end
  end

  defp download_torrent_file(url, indexer_name) do
    Logger.info("Downloading file from URL: #{url}")

    # Get download config for the indexer (cookies and FlareSolverr setting)
    download_config = get_indexer_download_config(indexer_name)

    if download_config.flaresolverr_enabled do
      Logger.info("Using FlareSolverr for download from: #{indexer_name}")
      download_via_flaresolverr(url, download_config.cookies)
    else
      download_direct(url, download_config.cookie_header)
    end
  end

  # Encodes a URL to ensure special characters in the path are properly escaped.
  # This handles URLs with spaces, brackets, and other characters that would
  # otherwise cause Req to fail with :invalid_request_target.
  # Example: "http://host/path/Movie Title (2008).nzb" becomes
  #          "http://host/path/Movie%20Title%20%282008%29.nzb"
  defp encode_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: nil} = uri ->
        # No path to encode
        URI.to_string(uri)

      %URI{path: path} = uri ->
        # Encode only the path portion, preserving the rest
        # Split path into segments and encode each one
        encoded_path =
          path
          |> String.split("/")
          |> Enum.map_join("/", fn segment ->
            # URI.encode/2 encodes special characters but preserves already-encoded ones
            URI.encode(segment, &URI.char_unreserved?/1)
          end)

        URI.to_string(%{uri | path: encoded_path})
    end
  end

  # Download directly with cookies
  defp download_direct(url, cookie_header) do
    if cookie_header != "" do
      Logger.debug("Using auth cookies for download")
    end

    # Encode the URL to handle special characters (spaces, brackets, etc.)
    encoded_url = encode_url(url)

    # First check if the URL redirects to a magnet link
    # by manually following redirects (Req can't handle magnet: scheme)
    case follow_to_final_url(encoded_url, cookie_header) do
      {:ok, {:magnet, magnet_url}} ->
        Logger.debug("URL redirected to magnet link")
        {:ok, {:magnet, magnet_url}}

      {:ok, {:http, final_url}} ->
        # Download the actual torrent file with auth cookies
        req_opts = if cookie_header != "", do: [headers: [{"cookie", cookie_header}]], else: []

        case Req.get(final_url, req_opts) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            Logger.info("Successfully downloaded file (#{byte_size(body)} bytes)")

            Logger.info(
              "Content preview (first 500 chars): #{inspect(String.slice(body, 0, 500))}"
            )

            classify_body(body)

          {:ok, %{status: status, body: body}} ->
            # Log the response body for debugging - it often contains error details
            body_preview =
              if is_binary(body) and byte_size(body) > 0 do
                String.slice(to_string(body), 0, 1000)
              else
                "(empty body)"
              end

            Logger.error(
              "Failed to download torrent file: HTTP #{status}, response: #{body_preview}"
            )

            {:error, {:download_failed, "HTTP #{status}: #{body_preview}"}}

          {:error, exception} ->
            Logger.error("Failed to download torrent file: #{inspect(exception)}")
            {:error, {:download_failed, "Connection error: #{inspect(exception)}"}}
        end

      {:error, :too_many_redirects} ->
        Logger.error("Too many redirects when downloading from: #{url}")
        {:error, {:download_failed, "Too many redirects (maximum 10)"}}

      {:error, {:redirect_error, message}} ->
        Logger.error("Redirect error for #{url}: #{message}")
        {:error, {:download_failed, "Redirect error: #{message}"}}

      {:error, {:http_error, exception}} ->
        Logger.error("HTTP error when downloading from #{url}: #{inspect(exception)}")
        {:error, {:download_failed, "Connection failed: #{inspect(exception)}"}}

      {:error, {:unexpected_status, status}} ->
        Logger.error("Unexpected HTTP status #{status} when downloading from: #{url}")
        {:error, {:download_failed, "Unexpected HTTP status: #{status}"}}

      {:error, reason} ->
        Logger.error("Failed to download torrent file from #{url}: #{inspect(reason)}")
        {:error, {:download_failed, inspect(reason)}}
    end
  end

  # Download via FlareSolverr for Cloudflare-protected sites
  defp download_via_flaresolverr(url, cookies) do
    alias Mydia.Indexers.FlareSolverr

    if FlareSolverr.enabled?() do
      # Pass cookies to FlareSolverr request
      flaresolverr_opts =
        if cookies != [] do
          [cookies: cookies]
        else
          []
        end

      case FlareSolverr.get(url, flaresolverr_opts) do
        {:ok, response} ->
          body = response.solution.response

          if is_binary(body) and byte_size(body) > 0 do
            Logger.info("FlareSolverr downloaded file (#{byte_size(body)} bytes)")
            classify_body(body)
          else
            Logger.error("FlareSolverr returned empty response for: #{url}")
            {:error, {:download_failed, "Empty response from FlareSolverr"}}
          end

        {:error, reason} ->
          Logger.error("FlareSolverr download failed: #{inspect(reason)}")
          {:error, {:download_failed, "FlareSolverr error: #{inspect(reason)}"}}
      end
    else
      Logger.error("FlareSolverr required but not enabled/configured")
      {:error, {:download_failed, "FlareSolverr required but not configured"}}
    end
  end

  defp follow_to_final_url(url, cookie_header, redirects_remaining \\ 10)
  defp follow_to_final_url(_url, _cookie_header, 0), do: {:error, :too_many_redirects}

  defp follow_to_final_url(url, cookie_header, redirects_remaining) do
    # Build request options with cookies if available
    req_opts =
      [redirect: false] ++
        if(cookie_header != "", do: [headers: [{"cookie", cookie_header}]], else: [])

    # Try HEAD request first - use redirect: false to get redirect responses directly
    # instead of following them, which avoids exception handling
    case Req.head(url, req_opts) do
      {:ok, %{status: status} = response} when status in 301..308 ->
        # This is a redirect response
        case get_location_header(response.headers) do
          nil ->
            Logger.error("Redirect (#{status}) missing Location header for URL: #{url}")
            {:error, {:redirect_error, "Redirect missing Location header"}}

          location ->
            if String.starts_with?(location, "magnet:") do
              {:ok, {:magnet, location}}
            else
              # Follow the redirect, encoding the location URL to handle special characters
              follow_to_final_url(encode_url(location), cookie_header, redirects_remaining - 1)
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: 405}} ->
        # HEAD not allowed, try GET as fallback
        follow_to_final_url_with_get(url, cookie_header, redirects_remaining)

      {:ok, %{status: status, body: body}} ->
        body_preview =
          if is_binary(body) and byte_size(body) > 0 do
            String.slice(to_string(body), 0, 500)
          else
            "(empty body)"
          end

        Logger.error(
          "Unexpected HTTP status #{status} during redirect check for URL: #{url}, response: #{body_preview}"
        )

        {:error, {:unexpected_status, status}}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected HTTP status #{status} during redirect check for URL: #{url}")
        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  defp follow_to_final_url_with_get(url, cookie_header, redirects_remaining) do
    # Fallback to GET when HEAD is not allowed
    # Build request options with cookies if available
    req_opts =
      [redirect: false] ++
        if(cookie_header != "", do: [headers: [{"cookie", cookie_header}]], else: [])

    case Req.get(url, req_opts) do
      {:ok, %{status: status} = response} when status in 301..308 ->
        # This is a redirect response
        case get_location_header(response.headers) do
          nil ->
            Logger.error("Redirect (#{status}) missing Location header for URL: #{url}")
            {:error, {:redirect_error, "Redirect missing Location header"}}

          location ->
            if String.starts_with?(location, "magnet:") do
              {:ok, {:magnet, location}}
            else
              # Follow the redirect, encoding the location URL to handle special characters
              follow_to_final_url(encode_url(location), cookie_header, redirects_remaining - 1)
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: status, body: body}} ->
        body_preview =
          if is_binary(body) and byte_size(body) > 0 do
            String.slice(to_string(body), 0, 500)
          else
            "(empty body)"
          end

        Logger.error(
          "Unexpected HTTP status #{status} during GET redirect check for URL: #{url}, response: #{body_preview}"
        )

        {:error, {:unexpected_status, status}}

      {:ok, %{status: status}} ->
        Logger.error("Unexpected HTTP status #{status} during GET redirect check for URL: #{url}")

        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  defp get_location_header(headers) do
    Enum.find_value(headers, fn
      {key, [value | _]} when key in ["location", "Location"] -> value
      {key, value} when key in ["location", "Location"] and is_binary(value) -> value
      _ -> nil
    end)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Get download configuration for an indexer by name
  # Returns a map with cookies (formatted as header string) and flaresolverr_enabled flag
  defp get_indexer_download_config(nil) do
    %{cookie_header: "", cookies: [], flaresolverr_enabled: false}
  end

  defp get_indexer_download_config(indexer_name) when is_binary(indexer_name) do
    case Mydia.Indexers.get_cardigann_download_config(indexer_name) do
      nil ->
        %{cookie_header: "", cookies: [], flaresolverr_enabled: false}

      config ->
        %{
          cookie_header: format_cookies_for_header(config.cookies),
          cookies: config.cookies,
          flaresolverr_enabled: config.flaresolverr_enabled
        }
    end
  end

  # Convert cookie list to header string
  # Handles both map format (from FlareSolverr) and string format
  defp format_cookies_for_header([]), do: ""

  defp format_cookies_for_header(cookies) when is_list(cookies) do
    cookies
    |> Enum.map(&format_single_cookie/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.join("; ")
  end

  defp format_single_cookie(%{"name" => name, "value" => value}) when is_binary(name) do
    "#{name}=#{value}"
  end

  defp format_single_cookie(%{name: name, value: value}) when is_binary(name) do
    "#{name}=#{value}"
  end

  defp format_single_cookie(cookie) when is_binary(cookie) do
    # Already a string like "name=value" or "name=value; path=/"
    # Extract just the name=value part
    cookie |> String.split(";") |> List.first() |> String.trim()
  end

  defp format_single_cookie(_), do: nil

  # Classifies a downloaded response body into a magnet link, a torrent/NZB
  # file, or an HTML page from which a magnet link can be scraped.
  #
  # Detection is structural (see ContentType) so trackerless torrents — whose
  # bencode dictionaries do not begin with `8:announce` — are recognised.
  defp classify_body(body) when is_binary(body) and byte_size(body) > 0 do
    case ContentType.detect(body) do
      :magnet ->
        {:ok, {:magnet, String.trim(body)}}

      type when type in [:torrent, :nzb] ->
        Logger.info("Detected #{type} file (#{byte_size(body)} bytes)")
        {:ok, {:file, body, type}}

      :unknown ->
        case extract_magnet_from_html(body) do
          {:ok, magnet_url} ->
            Logger.info("Extracted magnet link from HTML page")
            {:ok, {:magnet, magnet_url}}

          {:error, :no_magnet_found} ->
            Logger.error(
              "Downloaded body was not a recognised torrent/NZB/magnet, and no magnet link was found inside it"
            )

            {:error,
             {:download_failed, "Downloaded content was not a torrent, NZB, or magnet link"}}
        end
    end
  end

  defp classify_body(_),
    do: {:error, {:download_failed, "Empty response body"}}

  # Extracts a magnet link from HTML content
  # This is used when FlareSolverr returns an HTML page (e.g., 1337x torrent detail page)
  # instead of a torrent file
  defp extract_magnet_from_html(html) when is_binary(html) do
    # Parse HTML and look for magnet links
    case Floki.parse_document(html) do
      {:ok, document} ->
        # Try multiple strategies to find magnet links

        # Strategy 1: Look for anchor tags with href starting with "magnet:"
        magnet_links =
          document
          |> Floki.find("a[href^='magnet:']")
          |> Floki.attribute("href")

        # Strategy 2: Also check for data attributes or onclick handlers that might contain magnet
        magnet_from_data =
          if magnet_links == [] do
            document
            |> Floki.find("[data-href^='magnet:'], [data-url^='magnet:']")
            |> Floki.attribute("data-href")
            |> Kernel.++(
              document
              |> Floki.find("[data-href^='magnet:'], [data-url^='magnet:']")
              |> Floki.attribute("data-url")
            )
          else
            []
          end

        all_magnets = magnet_links ++ magnet_from_data

        # Strategy 3: Regex fallback - look for magnet links in raw HTML
        all_magnets =
          if all_magnets == [] do
            case Regex.scan(~r/magnet:\?xt=urn:[a-zA-Z0-9]+:[a-zA-Z0-9]+[^"'\s<>]*/, html) do
              [] -> []
              matches -> Enum.map(matches, fn [match] -> match end)
            end
          else
            all_magnets
          end

        case all_magnets do
          [magnet | _] ->
            # Clean up the magnet link (decode HTML entities)
            cleaned_magnet =
              magnet
              |> String.replace("&amp;", "&")
              |> String.trim()

            {:ok, cleaned_magnet}

          [] ->
            {:error, :no_magnet_found}
        end

      {:error, _reason} ->
        # Try regex fallback if Floki can't parse the HTML
        case Regex.run(~r/magnet:\?xt=urn:[a-zA-Z0-9]+:[a-zA-Z0-9]+[^"'\s<>]*/, html) do
          [magnet | _] ->
            cleaned_magnet =
              magnet
              |> String.replace("&amp;", "&")
              |> String.trim()

            {:ok, cleaned_magnet}

          nil ->
            {:error, :no_magnet_found}
        end
    end
  end

  defp extract_magnet_from_html(_), do: {:error, :no_magnet_found}
end
