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
  alias Mydia.{Media, Metadata, Repo}
  alias Mydia.Library.MetadataPreparation
  alias Mydia.Media.ExternalIds
  alias Mydia.Media.MediaItem
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
      - `:media_file_id` - Accepted for compatibility but never associated here

  ## Examples

      iex> match_result = %{provider_id: "603", provider_type: :tmdb, ...}
      iex> MetadataEnricher.enrich(match_result)
      {:ok, %MediaItem{title: "The Matrix", ...}}
  """
  def enrich(match_result, opts \\ [])

  def enrich(match_result, opts) do
    with {:ok, preparation} <- prepare(match_result, opts),
         {:ok, media_item} <- persist_in_transaction(preparation) do
      finalize(media_item)
      {:ok, media_item}
    end
  end

  @doc "Fetches all remote provider data without persisting metadata rows."
  @spec prepare(map(), keyword()) :: {:ok, MetadataPreparation.t()} | {:error, term()}
  def prepare(match_result, opts \\ [])

  def prepare(%{provider_id: provider_id, provider_type: provider_type} = match_result, opts)
      when is_binary(provider_id) and provider_type in [:tmdb, :tvdb] do
    config = Keyword.get(opts, :config, Metadata.default_relay_config())
    media_type = determine_media_type(match_result)

    Logger.info("Enriching media with full metadata",
      provider_id: provider_id,
      provider_type: provider_type,
      media_type: media_type,
      title: match_result.title,
      has_parsed_info: Map.has_key?(match_result, :parsed_info),
      parsed_info: Map.get(match_result, :parsed_info)
    )

    with {:ok, id} <- provider_id(provider_id),
         {:ok, preparation, metadata} <-
           prepare_media_item(id, provider_id, provider_type, media_type, match_result, config),
         {:ok, episode_seasons} <-
           prepare_episode_seasons(preparation, metadata, config, opts) do
      {:ok, %{preparation | episode_seasons: episode_seasons}}
    else
      {:error, reason} = error ->
        Logger.error("Failed to prepare media enrichment",
          provider_id: provider_id,
          reason: reason
        )

        error
    end
  end

  def prepare(match_result, _opts) do
    Logger.error("Invalid match result - missing provider_id or provider_type",
      has_provider_id: is_map(match_result) and Map.has_key?(match_result, :provider_id),
      has_provider_type: is_map(match_result) and Map.has_key?(match_result, :provider_type),
      keys: if(is_map(match_result), do: Map.keys(match_result), else: :not_a_map),
      title: if(is_map(match_result), do: Map.get(match_result, :title), else: nil)
    )

    {:error,
     {:invalid_match_result, "Match result missing required fields: provider_id or provider_type"}}
  end

  @doc "Persists prepared metadata. The caller must own the surrounding transaction."
  @spec persist(MetadataPreparation.t()) :: {:ok, MediaItem.t()} | {:error, term()}
  def persist(%MetadataPreparation{} = preparation) do
    with {:ok, media_item} <- persist_media_item(preparation),
         :ok <- persist_episode_seasons(media_item, preparation.episode_seasons) do
      {:ok, media_item}
    end
  end

  @doc "Runs filesystem metadata export after the database transaction commits."
  @spec finalize(MediaItem.t()) :: :ok
  def finalize(media_item), do: NfoWriter.maybe_write_nfos(media_item)

  ## Private Functions

  defp determine_media_type(%{parsed_info: %{type: :movie}}), do: :movie
  defp determine_media_type(%{parsed_info: %{type: :tv_show}}), do: :tv_show

  defp determine_media_type(%{metadata: %{media_type: media_type}})
       when media_type in [:movie, :tv_show],
       do: media_type

  defp determine_media_type(_), do: :movie

  defp provider_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, {:invalid_provider_id, value}}
    end
  end

  defp prepare_media_item(
         id,
         provider_id,
         provider_type,
         media_type,
         match_result,
         config
       ) do
    existing_item =
      if provider_type == :tvdb,
        do: Media.get_media_item_by_tvdb(id),
        else: Media.get_media_item_by_tmdb(id)

    case existing_item do
      nil ->
        Logger.debug("Preparing new media item", provider_id: provider_id, type: media_type)

        with {:ok, metadata} <-
               fetch_full_metadata(provider_id, media_type, config, provider_type, nil) do
          attrs = build_media_item_attrs(metadata, media_type, match_result)

          {:ok,
           %MetadataPreparation{
             provider_id: provider_id,
             provider_type: provider_type,
             media_type: media_type,
             operation: :create,
             media_item_attrs: attrs,
             episode_seasons: []
           }, metadata}
        else
          {:error, reason} -> {:error, {:metadata_fetch_failed, reason}}
        end

      existing_item ->
        prepare_existing_media_item(
          existing_item,
          provider_id,
          provider_type,
          media_type,
          config
        )
    end
  end

  defp prepare_existing_media_item(
         existing_item,
         provider_id,
         match_provider_type,
         media_type,
         config
       ) do
    cond do
      recently_enriched?(existing_item) and
        media_type == :tv_show and is_nil(existing_item.metadata_source) ->
        {:ok,
         preparation(
           existing_item,
           provider_id,
           match_provider_type,
           media_type,
           :stamp_source,
           %{
             metadata_source: match_provider_type
           }
         ), existing_item.metadata}

      recently_enriched?(existing_item) ->
        Logger.debug("Skipping metadata re-fetch for recently enriched item",
          id: existing_item.id,
          title: existing_item.title
        )

        {:ok,
         preparation(existing_item, provider_id, match_provider_type, media_type, :reuse, nil),
         existing_item.metadata}

      true ->
        provider_type = existing_item.metadata_source || match_provider_type

        case fetch_full_metadata(
               provider_id,
               media_type,
               config,
               provider_type,
               existing_item.season_order
             ) do
          {:ok, metadata} ->
            attrs =
              build_media_item_attrs(metadata, media_type, %{
                provider_type: provider_type,
                exclude_id: existing_item.id
              })

            {:ok,
             preparation(existing_item, provider_id, provider_type, media_type, :update, attrs),
             metadata}

          {:error, reason} ->
            Logger.warning("Failed to fetch updated metadata, returning existing item",
              id: existing_item.id,
              reason: reason
            )

            {:ok, preparation(existing_item, provider_id, provider_type, media_type, :reuse, nil),
             existing_item.metadata}
        end
    end
  end

  defp preparation(existing_item, provider_id, provider_type, media_type, operation, attrs) do
    %MetadataPreparation{
      provider_id: provider_id,
      provider_type: provider_type,
      media_type: media_type,
      operation: operation,
      media_item_id: existing_item.id,
      media_item_attrs: attrs,
      episode_seasons: []
    }
  end

  defp fetch_full_metadata(provider_id, media_type, config, provider_type, season_order) do
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

    # The show's recorded season ordering. This path runs against items that are
    # already in the library, so without it an ordinary rescan of a DVD-ordered
    # show overwrites its metadata blob with the official season list — the same
    # defect the refresh path was fixed for. nil (a brand new item, or a show
    # never asked) resolves to "official" in SeasonOrder.tvdb_type/1.
    fetch_opts =
      if media_type == :tv_show do
        Keyword.put(fetch_opts, :season_order, season_order)
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

  defp persist_in_transaction(preparation) do
    Repo.transaction(fn ->
      case persist(preparation) do
        {:ok, media_item} -> media_item
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp prepare_episode_seasons(preparation, metadata, config, opts) do
    should_fetch? =
      preparation.media_type == :tv_show and
        Keyword.get(opts, :fetch_episodes, true) and
        not episodes_exist_for_show?(preparation.media_item_id)

    if should_fetch? do
      fetch_episode_seasons(metadata, preparation.provider_id, config)
    else
      {:ok, []}
    end
  end

  defp persist_media_item(%MetadataPreparation{operation: :create, media_item_attrs: attrs}) do
    Media.create_media_item(attrs, skip_episode_refresh: true)
  end

  defp persist_media_item(%MetadataPreparation{
         operation: operation,
         media_item_id: media_item_id,
         media_item_attrs: attrs
       })
       when operation in [:update, :stamp_source] do
    case Repo.get(MediaItem, media_item_id) do
      nil -> {:error, {:media_item_missing, media_item_id}}
      media_item -> Media.update_media_item(media_item, attrs, reason: "Metadata enriched")
    end
  end

  defp persist_media_item(%MetadataPreparation{operation: :reuse, media_item_id: media_item_id}) do
    case Repo.get(MediaItem, media_item_id) do
      nil -> {:error, {:media_item_missing, media_item_id}}
      media_item -> {:ok, media_item}
    end
  end

  defp persist_episode_seasons(media_item, episode_seasons) do
    Enum.each(episode_seasons, &create_episodes_for_season(media_item, &1))
    :ok
  end

  defp fetch_episode_seasons(metadata, provider_id, config) do
    Logger.debug("Fetching episodes for TV show",
      provider_id: provider_id,
      title: if(is_map(metadata), do: Map.get(metadata, :title), else: nil)
    )

    # Get seasons list from metadata (includes tvdb_season_id if from TVDB)
    seasons = get_seasons_list(metadata)

    # The show's original language lets the TVDB season/episode fetch prefer the
    # original-language translation before falling back to English.
    original_language = LanguageCode.original_language_from(metadata)

    if seasons != [] do
      season_data =
        Enum.reduce(seasons, [], fn season, acc ->
          season_num = Map.get(season, :season_number, 0)
          tvdb_season_id = Map.get(season, :tvdb_season_id)

          fetch_opts =
            [tvdb_season_id: tvdb_season_id, original_language: original_language]
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)

          case Metadata.fetch_season_cached(config, provider_id, season_num, fetch_opts) do
            {:ok, fetched_season} ->
              [fetched_season | acc]

            {:error, reason} ->
              Logger.warning("Failed to fetch season data",
                provider_id: provider_id,
                season: season_num,
                reason: reason
              )

              acc
          end
        end)

      {:ok, Enum.reverse(season_data)}
    else
      Logger.warning("No season information available",
        provider_id: provider_id
      )

      {:ok, []}
    end
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

  # Checks if episodes already exist in the database for a given TV show.
  # Used to determine if we can skip the full episode enrichment HTTP calls.
  defp episodes_exist_for_show?(nil), do: false

  defp episodes_exist_for_show?(media_item_id) do
    import Ecto.Query, only: [from: 2]

    Repo.exists?(
      from(e in Mydia.Media.Episode, where: e.media_item_id == ^media_item_id, limit: 1)
    )
  end

  # Checks if a media item was recently enriched (within the last hour).
  # Used to skip redundant metadata re-fetches during bulk imports.
  defp recently_enriched?(media_item) do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
    DateTime.compare(media_item.updated_at, one_hour_ago) == :gt
  end
end
