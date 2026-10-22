defmodule Mydia.Jobs.MediaImport.FileImport do
  @moduledoc false

  require Logger
  alias Mydia.{Downloads, Library, Media}
  alias Mydia.Accounts.Scope
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Media.Episode
  alias Mydia.Jobs.MediaImport.{Discovery, Paths, Placement}

  @doc false
  def organize_and_import_files(download, files, library_path, args) do
    # Determine which files to import based on library type
    files_to_import = Discovery.filter_files_for_library_type(files, library_path.type)

    # Filter out extras, samples, and trailers
    files_to_import = Discovery.filter_extras_and_samples(files_to_import)
    parser_opts = parser_opts_for(download)

    if files_to_import == [] do
      Logger.warning("No importable files found in download",
        download_id: download.id,
        library_type: library_path.type
      )

      {:error, :no_importable_files}
    else
      # Import each file - destination path is determined per-file for TV shows.
      # Wrap each per-file import so a raised exception (e.g. a filesystem error
      # from a bang call deep in the path) is captured as {:error, ...} and
      # routed through handle_import_failure, instead of crashing the Oban job
      # silently and leaving the download stuck with no error on its row.
      results =
        Enum.map(files_to_import, fn file ->
          try do
            import_file(file, download, library_path, args, parser_opts)
          rescue
            exception ->
              Logger.error("Unhandled exception importing file",
                download_id: download.id,
                file: file.name,
                exception: Exception.message(exception),
                stacktrace: Exception.format_stacktrace(__STACKTRACE__)
              )

              {:error, {:import_exception, Exception.message(exception)}}
          end
        end)

      # Separate results into imported, unresolved, and errors. Skipped files
      # (season pack entries for episodes that already have a file) belong to
      # none of the three: they are a deliberate no-op, not a failure.
      {imported, unresolved, errors} =
        Enum.reduce(results, {[], [], []}, fn
          {:ok, media_file}, {imp, unr, err} -> {[media_file | imp], unr, err}
          {:unresolved, file_info}, {imp, unr, err} -> {imp, [file_info | unr], err}
          {:skipped, _info}, {imp, unr, err} -> {imp, unr, err}
          {:error, _} = error, {imp, unr, err} -> {imp, unr, [error | err]}
        end)

      imported = Enum.reverse(imported)
      unresolved = Enum.reverse(unresolved)

      placed_sources = Placement.placed_sources(Enum.map(files_to_import, & &1.path), results)

      cond do
        # All files imported successfully
        unresolved == [] and errors == [] ->
          {:ok, imported, placed_sources}

        # Some files imported, some unresolved (partial import)
        unresolved != [] and imported != [] ->
          flag_unresolved_files(download, unresolved)
          {:ok, imported, placed_sources}

        # No files imported, all unresolved
        unresolved != [] and imported == [] ->
          flag_unresolved_files(download, unresolved)
          {:error, :all_files_unresolved}

        # Total failure (nothing imported, nothing unresolved — only errors).
        # Surface a representative error reason instead of a generic
        # :partial_import so retry/terminal classification and the user-facing
        # message reflect the real cause (e.g. {:path_not_accessible, dir} when a
        # whole destination directory is unwritable, which is terminal after a
        # few attempts rather than retrying forever).
        imported == [] ->
          {:error, representative_error(errors)}

        # Some files imported, some failed — keep the partial-import signal so
        # the successfully-imported files are not undone by a terminal cancel,
        # but attach the representative underlying reason so the user-facing
        # message reflects the real cause instead of a generic hint.
        true ->
          {:error, {:partial_import, representative_error(errors)}}
      end
    end
  end

  # Picks a single error reason to represent a batch of per-file failures. When
  # the failures are uniform (the common case — e.g. the entire season directory
  # is unwritable) the first reason represents them all.
  @doc false
  def representative_error([{:error, reason} | _]), do: reason
  def representative_error(_), do: :partial_import

  # Returns "partial_pack" if a season-pack download delivered fewer distinct
  # episodes than the search-time metadata promised; otherwise nil. The infinite
  # re-download loop we hit in prod was bogus "season packs" that contained a
  # single episode file — without this check, the download was marked as
  # successfully imported and the next hourly search re-grabbed it.
  @doc false
  def detect_partial_pack(download, imported_files) do
    metadata = download.metadata || %{}
    expected_count = metadata["episode_count"]

    if not is_integer(expected_count) or expected_count <= 0 do
      nil
    else
      actual_count =
        imported_files
        |> Enum.map(& &1.episode_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length()

      if actual_count < expected_count do
        Logger.warning("Season pack delivered fewer episodes than promised",
          download_id: download.id,
          title: download.title,
          expected_episode_count: expected_count,
          matched_episode_count: actual_count
        )

        "partial_pack"
      end
    end
  end

  defp flag_unresolved_files(download, unresolved_files) do
    # Store unresolved file info in metadata and set match_status
    current_metadata = download.metadata || %{}

    unresolved_data =
      Enum.map(unresolved_files, fn file_info ->
        %{
          "path" => file_info.path,
          "name" => file_info.name,
          "size" => file_info.size,
          "parsed_season" => file_info.parsed_season,
          "parsed_episode" => file_info.parsed_episode,
          "assigned_episode_id" => nil
        }
      end)

    updated_metadata = Map.put(current_metadata, "unresolved_files", unresolved_data)

    case Downloads.update_download(download, %{
           match_status: "unresolved_files",
           metadata: updated_metadata
         }) do
      {:ok, _updated} ->
        Logger.info("Flagged download with #{length(unresolved_files)} unresolved file(s)",
          download_id: download.id
        )

        Downloads.broadcast_download_update(download.id)

      {:error, changeset} ->
        Logger.warning("Failed to flag unresolved files",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  # Build a `%TargetContext{}` from the download's preloaded
  # `%MediaItem{}` (with `:episodes`). Returns `nil` when the download
  # has no bound media item — the parser then runs unbound and infers
  # type/title/year from the filename.
  defp target_context_for(%{media_item: %Mydia.Media.MediaItem{} = media_item}) do
    TargetContext.from_media_item(media_item)
  end

  defp target_context_for(_download), do: nil

  @doc false
  def parser_opts_for(download) do
    case target_context_for(download) do
      nil -> []
      target -> [target: target]
    end
  end

  # Ensure `Media.refresh_episodes_for_tv_show/1` is invoked at most once
  # per Oban job per show. Each Oban worker call runs in its own process,
  # so the process dictionary gives us a job-scoped memoization key that
  # cleans itself up automatically when the job exits.
  #
  # The dedup target is the media_item id, not the season — a single
  # refresh call always pulls every season's episodes for the show, so
  # repeating it for another season number in the same job is pure waste.
  defp refresh_episodes_once(%Mydia.Media.MediaItem{id: id} = media_item, season) do
    key = {:media_import_refresh_attempted, id}

    if Process.get(key) do
      :already_attempted
    else
      Process.put(key, true)

      Logger.info("Episode not found, refreshing episodes for TV show",
        media_item: media_item.title,
        season: season
      )

      case Media.refresh_episodes_for_tv_show(media_item) do
        {:ok, count} ->
          Logger.info("Refreshed episodes, created #{count} episodes")
          {:ok, count}

        {:error, reason} = error ->
          Logger.error("Failed to refresh episodes",
            media_item: media_item.title,
            reason: inspect(reason)
          )

          error
      end
    end
  end

  defp import_file(file, download, library_path, args, parser_opts) do
    # Parse filename to extract episode info for TV shows. When the
    # download is already bound to a known `%MediaItem{}`, pass it as
    # a `%TargetContext{}` so the parser locks type / title / year and
    # focuses on season + episode + quality.
    parsed = ReleaseParser.parse(file.name, parser_opts)

    # Check if this is a season pack download
    is_season_pack = get_in(download.metadata, ["season_pack"]) == true
    season_pack_season = get_in(download.metadata, ["season_number"])

    # Determine episode and destination path
    {episode, dest_dir} =
      case {download.media_item, download.episode, parsed.type, is_season_pack} do
        # Season pack - the per-file filename is the authoritative season
        # hint when the parser found one. The download-level
        # `season_number` is only the originally-requested season; for
        # "Complete S01-S03" style packs containing files from multiple
        # seasons, every file would otherwise be force-matched to that
        # one season and most would fall through to `:unresolved` (or
        # worse, collapse onto a single episode row when episode_number
        # collides). Prefer parsed.season; fall back to season_pack_season
        # for files where the parser couldn't recover a season token.
        {%{type: "tv_show"} = media_item, _, :tv_show, true}
        when not is_nil(season_pack_season) and not is_nil(parsed.episodes) ->
          episode_number = List.first(parsed.episodes) || 1
          file_season = parsed.season || season_pack_season

          Logger.debug("Processing season pack file",
            file: file.name,
            season_pack_season: season_pack_season,
            file_season: file_season,
            episode_number: episode_number
          )

          episode =
            Media.get_episode_by_number(
              Scope.system(),
              media_item.id,
              file_season,
              episode_number
            )

          episode =
            if is_nil(episode) do
              # Refresh metadata at most ONCE per import job per show.
              # Calling refresh per-file was the metadata-relay hammer
              # behind the Good Omens incident: the in-memory media_item
              # struct stays stale across this Enum.map loop, so
              # `should_skip_season_refresh?` never tripped and every
              # unresolved file fired a fresh HTTP round-trip. After this
              # guard, the first miss does the refresh, subsequent misses
              # in the same job re-use whatever the refresh produced (or
              # the empty result if refresh failed).
              refresh_episodes_once(media_item, file_season)

              # Retry episode lookup regardless of refresh result —
              # another file in this same job may have just created the
              # episode row we need.
              Media.get_episode_by_number(
                Scope.system(),
                media_item.id,
                file_season,
                episode_number
              )
            else
              episode
            end

          if episode do
            Logger.debug("Found episode for season pack file",
              file: file.name,
              season: file_season,
              episode: episode_number,
              episode_id: episode.id
            )

            # Build destination path using the matched episode's actual
            # season — not the download-level season — so files from
            # `Complete S01-S03` packs land in the right `Season XX` dirs.
            base_dir = Paths.build_series_base_path(media_item, library_path, episode)

            dest_dir = Paths.season_dir(base_dir, media_item, library_path, file_season)

            {episode, dest_dir}
          else
            Logger.warning("Episode still not found after refresh attempt",
              file: file.name,
              season: file_season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Return :unresolved instead of importing with nil episode
            {:unresolved,
             %{
               path: file.path,
               name: file.name,
               size: file.size,
               parsed_season: file_season,
               parsed_episode: episode_number
             }}
          end

        # TV show with parsed episode info - look up the episode
        {%{type: "tv_show"} = media_item, _, :tv_show, _}
        when not is_nil(parsed.season) and not is_nil(parsed.episodes) ->
          episode_number = List.first(parsed.episodes) || 1

          episode =
            Media.get_episode_by_number(
              Scope.system(),
              media_item.id,
              parsed.season,
              episode_number
            )

          if episode do
            Logger.debug("Found episode for file",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              episode_id: episode.id
            )

            # Build destination path using parsed season info (category-aware)
            base_dir = Paths.build_series_base_path(media_item, library_path, episode)

            dest_dir = Paths.season_dir(base_dir, media_item, library_path, parsed.season)

            {episode, dest_dir}
          else
            Logger.warning("Episode not found in database, falling back to download episode",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Fall back to download episode and default path (category-aware)
            dest_dir = Paths.build_destination_path(download, library_path)
            {download.episode, dest_dir}
          end

        # TV show file where the parser found a season but no episode
        # number (e.g. `Show.S01.mkv`, or season-pack files that don't
        # carry an `SxxEyy` marker). Don't silently default to episode 1
        # — return :unresolved so the file shows up in the issues queue
        # for manual resolution.
        {%{type: "tv_show"} = media_item, _, :tv_show, _}
        when not is_nil(parsed.season) and is_nil(parsed.episodes) ->
          Logger.warning("TV file has parseable season but no episode number — skipping",
            file: file.name,
            season: parsed.season,
            media_item: media_item.title
          )

          {:unresolved,
           %{
             path: file.path,
             name: file.name,
             size: file.size,
             parsed_season: parsed.season,
             parsed_episode: nil
           }}

        # TV show but no parsed info - use download episode
        {%{type: "tv_show"}, episode, _, _} when not is_nil(episode) ->
          dest_dir = Paths.build_destination_path(download, library_path)
          {episode, dest_dir}

        # Movie or other - use download info (category-aware)
        _ ->
          dest_dir = Paths.build_destination_path(download, library_path)
          {download.episode, dest_dir}
      end

    tv_show? = match?(%{media_item: %{type: "tv_show"}}, download)

    # Handle unresolved files (season pack files where episode wasn't found)
    case {episode, dest_dir} do
      {:unresolved, file_info} ->
        {:unresolved, file_info}

      # A TV file that resolved to no episode, with no download episode to fall
      # back on. Importing it would attach it to the show itself, which the
      # media file changeset refuses: route it to the issues queue instead,
      # the same as a season-pack file whose episode is missing.
      {nil, _dest_dir} when tv_show? ->
        Logger.warning("TV file resolved to no episode; leaving it unresolved",
          download_id: download.id,
          file: file.name,
          season: parsed.season,
          episode: List.first(parsed.episodes || [])
        )

        {:unresolved,
         %{
           path: file.path,
           name: file.name,
           size: file.size,
           parsed_season: parsed.season,
           parsed_episode: List.first(parsed.episodes || [])
         }}

      {episode, dest_dir} ->
        if skip_already_filed_episode?(episode, download) do
          Logger.info("Skipping season pack file - episode already has a media file",
            download_id: download.id,
            file: file.name,
            episode_id: episode.id
          )

          {:skipped, %{name: file.name, episode_id: episode.id}}
        else
          Placement.import_file_to_destination(
            file,
            episode,
            dest_dir,
            download,
            library_path,
            args
          )
        end
    end
  end

  # A season pack legitimately contains episodes the library already has, now
  # that the grab guard only blocks a pack whose every targeted episode is on
  # disk. Importing those files would create a second non-trashed media_files
  # row for the episode: the importer's only existence check is on the
  # destination path, and there is no unique index on media_files.episode_id.
  #
  # Upgrades are exempt. An upgrade pack targets episodes that already have
  # files by definition, and its per-episode supersede pointer (see
  # supersede_target/3) is what trashes the loser after the margin gate.
  defp skip_already_filed_episode?(%Episode{id: episode_id}, download) do
    get_in(download.metadata, ["season_pack"]) == true and
      not upgrade_download?(download) and
      Library.episode_has_media_file?(episode_id)
  end

  defp skip_already_filed_episode?(_episode, _download), do: false

  defp upgrade_download?(download) do
    match?(%{"upgrade_target_media_file_id" => id} when is_binary(id), download.metadata)
  end
end
