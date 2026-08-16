defmodule Mydia.Library.MetadataEnricher do
  @moduledoc """
  Enriches media items with full metadata from providers.

  This module takes a matched media item (with provider ID) and:
  - Fetches detailed metadata (description, cast, crew, ratings, genres, etc.)
  - Downloads and stores poster/backdrop images
  - For TV shows, fetches and creates episode records
  - Stores everything in the database
  """

  require Logger
  alias Mydia.{Media, Metadata, Repo, Settings}
  alias Mydia.Media.ExternalIds
  alias Mydia.Metadata.LanguageCode
  alias Mydia.Metadata.NfoWriter

  @doc """
  Enriches a media item with full metadata from the provider.

  Takes a match result from MetadataMatcher and fetches/stores all metadata.

  ## Parameters
    - `match_result` - Result from MetadataMatcher.match_file/2
    - `opts` - Options
      - `:config` - Provider configuration (default: Metadata.default_relay_config())
      - `:fetch_episodes` - For TV shows, whether to fetch episode data (default: true)
      - `:media_file_id` - Optional media file ID to associate

  ## Examples

      iex> match_result = %{provider_id: "603", provider_type: :tmdb, ...}
      iex> MetadataEnricher.enrich(match_result)
      {:ok, %MediaItem{title: "The Matrix", ...}}
  """
  def enrich(match_result, opts \\ [])

  def enrich(%{provider_id: provider_id, provider_type: provider_type} = match_result, opts)
      when not is_nil(provider_id) and not is_nil(provider_type) do
    config = Keyword.get(opts, :config, Metadata.default_relay_config())
    media_file_id = Keyword.get(opts, :media_file_id)

    media_type = determine_media_type(match_result)

    Logger.info("Enriching media with full metadata",
      provider_id: provider_id,
      provider_type: provider_type,
      media_type: media_type,
      title: match_result.title,
      media_file_id: media_file_id,
      has_parsed_info: Map.has_key?(match_result, :parsed_info),
      parsed_info: Map.get(match_result, :parsed_info)
    )

    # Validate library type compatibility if we have a media file
    with :ok <- validate_library_type_compatibility(media_type, media_file_id) do
      # Check if media item already exists
      case get_or_create_media_item(provider_id, media_type, match_result, config) do
        {:ok, media_item} ->
          # Associate media file with media_item for movies only
          # For TV shows, files are associated with episodes instead
          if media_file_id && media_type == :movie do
            associate_media_file(media_item, media_file_id)
          end

          # For TV shows, fetch and create episodes
          if media_type == :tv_show and Keyword.get(opts, :fetch_episodes, true) do
            # Add media_file_id to match_result so it can be used for episode file association
            match_result_with_file_id =
              if media_file_id do
                Logger.debug(
                  "Adding media_file_id to match_result for episode association: " <>
                    "media_file_id=#{inspect(media_file_id)}, " <>
                    "season=#{inspect(match_result.parsed_info.season)}, " <>
                    "episodes=#{inspect(match_result.parsed_info.episodes)}"
                )

                Map.put(match_result, :media_file_id, media_file_id)
              else
                Logger.warning("No media_file_id provided for TV show import")
                match_result
              end

            # Fast path: if episodes already exist, skip full enrichment and
            # just associate the file with its target episode via DB lookup
            if episodes_exist_for_show?(media_item) do
              Logger.debug("Fast path: episodes exist, skipping enrichment",
                media_item_id: media_item.id,
                title: media_item.title
              )

              associate_file_with_target_episodes(media_item, match_result_with_file_id)
            else
              enrich_episodes(media_item, provider_id, config, match_result_with_file_id)
            end
          end

          NfoWriter.maybe_write_nfos(media_item)

          {:ok, media_item}

        {:error, reason} = error ->
          Logger.error("Failed to enrich media",
            provider_id: provider_id,
            reason: reason
          )

          error
      end
    else
      {:error, reason} = error ->
        Logger.error("Library type validation failed",
          provider_id: provider_id,
          media_type: media_type,
          media_file_id: media_file_id,
          reason: reason
        )

        error
    end
  end

  # Fallback clause for invalid match results (missing provider_id or provider_type)
  def enrich(match_result, _opts) do
    Logger.error("Invalid match result - missing provider_id or provider_type",
      has_provider_id: is_map(match_result) and Map.has_key?(match_result, :provider_id),
      has_provider_type: is_map(match_result) and Map.has_key?(match_result, :provider_type),
      keys: if(is_map(match_result), do: Map.keys(match_result), else: :not_a_map),
      title: if(is_map(match_result), do: Map.get(match_result, :title), else: nil)
    )

    {:error,
     {:invalid_match_result, "Match result missing required fields: provider_id or provider_type"}}
  end

  ## Private Functions

  defp determine_media_type(%{parsed_info: %{type: :movie}}), do: :movie
  defp determine_media_type(%{parsed_info: %{type: :tv_show}}), do: :tv_show

  defp determine_media_type(%{metadata: %{media_type: media_type}})
       when media_type in [:movie, :tv_show],
       do: media_type

  defp determine_media_type(_), do: :movie

  defp get_or_create_media_item(provider_id, media_type, match_result, config) do
    provider_type = Map.get(match_result, :provider_type, :tmdb)
    id = String.to_integer(provider_id)

    # Look up existing item by the appropriate provider ID
    existing_item =
      if provider_type == :tvdb do
        Media.get_media_item_by_tvdb(id)
      else
        Media.get_media_item_by_tmdb(id)
      end

    case existing_item do
      nil ->
        # Fetch full metadata and create new item
        create_new_media_item(provider_id, media_type, match_result, config)

      item ->
        # Update existing item with latest metadata. Pass the match's resolved
        # provider so a nil-source item can adopt it (see provenance handling
        # in update_existing_media_item/5).
        update_existing_media_item(item, provider_id, media_type, config, provider_type)
    end
  end

  defp create_new_media_item(provider_id, media_type, match_result, config) do
    Logger.debug("Creating new media item", provider_id: provider_id, type: media_type)

    provider_type = Map.get(match_result, :provider_type, :tmdb)

    case fetch_full_metadata(provider_id, media_type, config, provider_type) do
      {:ok, full_metadata} ->
        attrs = build_media_item_attrs(full_metadata, media_type, match_result)

        case Media.create_media_item(attrs, skip_episode_refresh: true) do
          {:ok, media_item} ->
            # Episodes will be fetched by enrich_episodes if needed
            {:ok, media_item}

          error ->
            error
        end

      {:error, reason} ->
        {:error, {:metadata_fetch_failed, reason}}
    end
  end

  defp update_existing_media_item(
         existing_item,
         provider_id,
         media_type,
         config,
         match_provider_type
       ) do
    # Skip re-fetching metadata if the item was recently updated (within the last hour)
    # This avoids redundant HTTP calls when importing multiple files for the same show
    if recently_enriched?(existing_item) do
      maybe_stamp_recently_enriched(existing_item, media_type, match_provider_type)
    else
      Logger.debug("Updating existing media item",
        id: existing_item.id,
        provider_id: provider_id
      )

      # An explicit `metadata_source` is authoritative provenance and wins
      # (preserve behavior from f1e4840f). Otherwise a nil-source item adopts
      # the match's resolved provider. We never infer from id presence:
      # maybe_discover_tvdb_id back-fills tvdb_id onto TMDB-matched shows, so
      # id-inference would mis-stamp dual-id rows.
      provider_type = existing_item.metadata_source || match_provider_type

      case fetch_full_metadata(provider_id, media_type, config, provider_type) do
        {:ok, full_metadata} ->
          # `exclude_id` matters only here: the row already exists and usually
          # already owns the cross-referenced id, so without it the item is
          # found as the owner of its own id, the id is dropped and the
          # operator gets a spurious duplicate warning out of an ordinary scan.
          attrs =
            build_media_item_attrs(full_metadata, media_type, %{
              provider_type: provider_type,
              exclude_id: existing_item.id
            })

          Media.update_media_item(existing_item, attrs, reason: "Metadata enriched")

        {:error, reason} ->
          Logger.warning("Failed to fetch updated metadata, returning existing item",
            id: existing_item.id,
            reason: reason
          )

          {:ok, existing_item}
      end
    end
  end

  # Within the freshness window we skip the relay re-fetch, but a nil-source TV
  # item must still record provenance — otherwise self-heal would silently
  # no-op for items rescanned within the hour. Stamp only (no relay call);
  # items that already carry a source are left untouched.
  defp maybe_stamp_recently_enriched(
         %{metadata_source: nil} = existing_item,
         :tv_show,
         provider_type
       )
       when not is_nil(provider_type) do
    Media.update_media_item(existing_item, %{metadata_source: provider_type},
      reason: "Provenance recorded"
    )
  end

  defp maybe_stamp_recently_enriched(existing_item, _media_type, _provider_type) do
    Logger.debug("Skipping metadata re-fetch for recently enriched item",
      id: existing_item.id,
      title: existing_item.title
    )

    {:ok, existing_item}
  end

  defp fetch_full_metadata(provider_id, media_type, config, provider_type) do
    fetch_opts = [
      media_type: media_type,
      append_to_response: Metadata.default_append_to_response(media_type)
    ]

    # For TV shows, fetch from the provider that supplied the match so a
    # TMDB-matched show is not fetched from the TVDB endpoint (and vice versa).
    fetch_opts =
      if media_type == :tv_show && provider_type in [:tvdb, :tmdb] do
        Keyword.put(fetch_opts, :provider, provider_type)
      else
        fetch_opts
      end

    Metadata.fetch_by_id_cached(config, provider_id, fetch_opts)
  end

  defp build_media_item_attrs(metadata, media_type, match_result) do
    provider_id = String.to_integer(to_string(metadata.provider_id))

    raw_provider_type = Map.get(match_result, :provider_type, metadata.provider || :tmdb)
    provider_type = normalize_provider_type(raw_provider_type, metadata)

    attrs = %{
      type: media_type_to_string(media_type),
      title: metadata.title,
      original_title: metadata.original_title,
      year: extract_year(metadata),
      imdb_id: metadata.imdb_id,
      metadata: metadata,
      monitored: true
    }

    # Set the id of the provider that produced the match, then add whatever
    # cross-reference that provider published. A show matched on TVDB used to
    # be stored with tmdb_id nil, which made Discover render an Add button for
    # something already in the library.
    attrs =
      if provider_type == :tvdb do
        Map.put(attrs, :tvdb_id, provider_id)
      else
        Map.put(attrs, :tmdb_id, provider_id)
      end

    # `:exclude_id` is absent on the create path -- there is no row yet, so
    # every owner found really is a different item.
    attrs =
      ExternalIds.put_free_ids(attrs, metadata.external_ids,
        exclude_id: Map.get(match_result, :exclude_id)
      )

    # Record provenance for TV shows so provider-aware refresh can detect a
    # source/library mismatch. Movies leave metadata_source nil.
    #
    # quality_profile_id is deliberately left unset. A nil profile means "follow
    # whatever default is configured", resolved at search time by
    # Mydia.Indexers.QualityProfileResolver. Stamping the current default here
    # would freeze it onto every scanned item, so changing the default later
    # would leave the whole library behind on the old one.
    if media_type == :tv_show do
      Map.put(attrs, :metadata_source, provider_type)
    else
      attrs
    end
  end

  # Normalize any provider signal to a concrete :tvdb / :tmdb value. Search
  # results from the relay carry provider: :metadata_relay for TMDB, which must
  # map to :tmdb rather than leak through as an invalid metadata_source.
  defp normalize_provider_type(:tvdb, _metadata), do: :tvdb
  defp normalize_provider_type(:tmdb, _metadata), do: :tmdb
  defp normalize_provider_type(_other, %{provider: :tvdb}), do: :tvdb
  defp normalize_provider_type(_other, _metadata), do: :tmdb

  defp media_type_to_string(:movie), do: "movie"
  defp media_type_to_string(:tv_show), do: "tv_show"

  defp extract_year(metadata) do
    cond do
      metadata.release_date ->
        extract_year_from_date(metadata.release_date)

      metadata.first_air_date ->
        extract_year_from_date(metadata.first_air_date)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_year_from_date(%Date{} = date), do: date.year

  defp extract_year_from_date(date_string) when is_binary(date_string) do
    date_string
    |> String.slice(0..3)
    |> String.to_integer()
  end

  defp extract_year_from_date(_), do: nil

  defp associate_media_file(media_item, media_file_id) do
    # Update the media file to associate it with this media item
    media_file = Mydia.Library.get_media_file!(media_file_id)

    case Mydia.Library.update_media_file(media_file, %{media_item_id: media_item.id}) do
      {:ok, _updated_file} ->
        Logger.debug("Associated media file with media item",
          media_file_id: media_file_id,
          media_item_id: media_item.id
        )

        :ok

      {:error, changeset} ->
        Logger.error("Failed to associate media file with media item",
          media_file_id: media_file_id,
          media_item_id: media_item.id,
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  rescue
    error ->
      Logger.error("Exception while associating media file with media item",
        media_file_id: media_file_id,
        media_item_id: media_item.id,
        error: Exception.message(error)
      )

      {:error, error}
  end

  defp enrich_episodes(media_item, provider_id, config, match_result) do
    Logger.debug("Fetching episodes for TV show",
      media_item_id: media_item.id,
      title: media_item.title
    )

    # Get seasons list from metadata (includes tvdb_season_id if from TVDB)
    seasons = get_seasons_list(media_item.metadata)

    # The show's original language lets the TVDB season/episode fetch prefer the
    # original-language translation before falling back to English.
    original_language = LanguageCode.original_language_from(media_item.metadata)

    if seasons != [] do
      # Fetch and create/update all episodes
      Enum.each(seasons, fn season ->
        season_num = Map.get(season, :season_number, 0)
        tvdb_season_id = Map.get(season, :tvdb_season_id)

        fetch_opts =
          [tvdb_season_id: tvdb_season_id, original_language: original_language]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        case Metadata.fetch_season_cached(config, provider_id, season_num, fetch_opts) do
          {:ok, season_data} ->
            create_episodes_for_season(media_item, season_data)

          {:error, reason} ->
            Logger.warning("Failed to fetch season data",
              media_item_id: media_item.id,
              season: season_num,
              reason: reason
            )
        end
      end)

      # After all episodes are created, directly associate the file with the target episode(s)
      associate_file_with_target_episodes(media_item, match_result)
    else
      Logger.warning("No season information available",
        media_item_id: media_item.id
      )
    end

    :ok
  end

  defp get_seasons_list(%{seasons: seasons}) when is_list(seasons) do
    # Filter out season 0 (specials) for now
    Enum.filter(seasons, fn s -> Map.get(s, :season_number, 0) > 0 end)
  end

  defp get_seasons_list(%{number_of_seasons: num}) when is_integer(num) and num > 0 do
    # Fallback: create basic season entries without tvdb_season_id
    Enum.map(1..num, fn n -> %{season_number: n} end)
  end

  defp get_seasons_list(_), do: []

  defp create_episodes_for_season(media_item, season_data) do
    {:ok, count} =
      Media.upsert_episodes_from_season(media_item, season_data,
        monitor_new?: Media.should_monitor_new_episode?(media_item, season_data.season_number)
      )

    Logger.debug("Upserted #{count} episodes",
      media_item_id: media_item.id,
      season: season_data.season_number
    )
  end

  # Directly associates the media file with target episodes using O(1) lookups
  # instead of iterating through all episodes
  defp associate_file_with_target_episodes(
         media_item,
         %{
           parsed_info: %{season: season, episodes: episode_numbers},
           media_file_id: media_file_id
         }
       )
       when is_binary(media_file_id) and is_list(episode_numbers) do
    Logger.debug("Associating file with target episodes via direct lookup",
      media_item_id: media_item.id,
      season: season,
      episode_numbers: episode_numbers,
      media_file_id: media_file_id
    )

    # Direct lookup for each target episode - O(k) where k is the number of episodes in the file
    # Typically k=1, sometimes k=2 for double episodes
    Enum.each(episode_numbers, fn episode_number ->
      case Media.get_episode_by_number(media_item.id, season, episode_number) do
        nil ->
          Logger.warning("Target episode not found for file association",
            media_item_id: media_item.id,
            season: season,
            episode: episode_number
          )

        episode ->
          associate_media_file_with_episode(episode, media_file_id)
      end
    end)
  end

  defp associate_file_with_target_episodes(_media_item, match_result) do
    # No media_file_id or parsed_info - nothing to associate
    Logger.debug("Skipping file association - no media_file_id or parsed episode info",
      has_media_file_id: Map.has_key?(match_result, :media_file_id),
      has_parsed_info: Map.has_key?(match_result, :parsed_info)
    )

    :ok
  end

  defp associate_media_file_with_episode(episode, media_file_id) do
    media_file =
      Mydia.Library.get_media_file!(media_file_id)
      |> Mydia.Repo.preload(:library_path)

    case Mydia.Library.update_media_file(media_file, %{episode_id: episode.id}) do
      {:ok, _updated_file} ->
        Logger.debug("Associated file with episode",
          episode_id: episode.id,
          season: episode.season_number,
          episode: episode.episode_number,
          media_file_id: media_file_id
        )

      {:error, changeset} ->
        Logger.error("Failed to associate file with episode",
          episode_id: episode.id,
          media_file_id: media_file_id,
          errors: inspect(changeset.errors)
        )
    end
  rescue
    error ->
      Logger.error("Exception associating file with episode",
        episode_id: episode.id,
        media_file_id: media_file_id,
        error: inspect(error)
      )

      :ok
  end

  # Checks if episodes already exist in the database for a given TV show.
  # Used to determine if we can skip the full episode enrichment HTTP calls.
  defp episodes_exist_for_show?(media_item) do
    import Ecto.Query, only: [from: 2]

    Repo.exists?(
      from(e in Mydia.Media.Episode, where: e.media_item_id == ^media_item.id, limit: 1)
    )
  end

  # Checks if a media item was recently enriched (within the last hour).
  # Used to skip redundant metadata re-fetches during bulk imports.
  defp recently_enriched?(media_item) do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
    DateTime.compare(media_item.updated_at, one_hour_ago) == :gt
  end

  # Validates that the media type is compatible with the library path type
  defp validate_library_type_compatibility(_media_type, nil) do
    # No media file, skip validation
    :ok
  end

  defp validate_library_type_compatibility(media_type, media_file_id)
       when is_binary(media_file_id) do
    case Mydia.Repo.get(Mydia.Library.MediaFile, media_file_id)
         |> Mydia.Repo.preload(:library_path) do
      nil ->
        # Media file not found, let it proceed (will fail later with better error)
        :ok

      media_file ->
        validate_media_type_against_library_path(media_type, media_file)
    end
  rescue
    error ->
      Logger.error("Exception during library type validation",
        media_type: media_type,
        media_file_id: media_file_id,
        error: inspect(error)
      )

      # Allow to proceed if validation itself fails
      :ok
  end

  defp validate_media_type_against_library_path(media_type, media_file) do
    absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)
    library_path = find_library_path_for_file(absolute_path)
    media_type_string = media_type_to_string(media_type)

    cond do
      # No library path found, allow the operation
      is_nil(library_path) ->
        :ok

      # Library is :mixed, allow both types
      library_path.type == :mixed ->
        :ok

      # Specialized library types (music, books, adult) should not have movie/TV metadata enrichment
      library_path.type in [:music, :books, :adult] ->
        emit_type_mismatch_telemetry(media_type_string, library_path)

        Logger.warning(
          "Type mismatch: Cannot enrich #{media_type_string} metadata in specialized library",
          media_type: media_type_string,
          library_path: library_path.path,
          library_type: library_path.type,
          file_path: absolute_path
        )

        {:error,
         {:library_type_mismatch,
          "Cannot add #{media_type_string} to a library path configured for #{library_path.type} (path: #{library_path.path})"}}

      # Movie in :series library
      media_type_string == "movie" and library_path.type == :series ->
        emit_type_mismatch_telemetry(media_type_string, library_path)

        Logger.warning("Type mismatch: Cannot add movies to series-only library",
          media_type: media_type_string,
          library_path: library_path.path,
          library_type: library_path.type,
          file_path: absolute_path
        )

        {:error,
         {:library_type_mismatch,
          "Cannot add movies to a library path configured for TV series only (path: #{library_path.path})"}}

      # TV show in :movies library
      media_type_string == "tv_show" and library_path.type == :movies ->
        emit_type_mismatch_telemetry(media_type_string, library_path)

        Logger.warning("Type mismatch: Cannot add TV shows to movies-only library",
          media_type: media_type_string,
          library_path: library_path.path,
          library_type: library_path.type,
          file_path: absolute_path
        )

        {:error,
         {:library_type_mismatch,
          "Cannot add TV shows to a library path configured for movies only (path: #{library_path.path})"}}

      # All other cases are valid
      true ->
        :ok
    end
  end

  # Finds the library path that contains the given file path
  # Prefers the longest matching prefix (most specific path)
  defp find_library_path_for_file(file_path) do
    library_paths = Settings.list_library_paths()

    library_paths
    |> Enum.filter(fn library_path ->
      String.starts_with?(file_path, library_path.path)
    end)
    |> Enum.max_by(
      fn library_path -> String.length(library_path.path) end,
      fn -> nil end
    )
  end

  # Emits telemetry event for type mismatch tracking
  defp emit_type_mismatch_telemetry(media_type, library_path) do
    :telemetry.execute(
      [:mydia, :library, :type_mismatch],
      %{count: 1},
      %{
        media_type: media_type,
        library_type: library_path.type,
        library_path: library_path.path
      }
    )
  end
end
