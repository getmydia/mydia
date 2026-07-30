defmodule MydiaWeb.Live.Helpers.MediaAddHelpers do
  @moduledoc """
  Shared helpers for adding media items to the library from external metadata.

  Used by DashboardLive and DiscoverLive for the "Add to Library" flow.
  """

  alias Mydia.Media
  alias Mydia.Metadata
  alias Mydia.Settings

  @doc """
  Enriches a list of search result items with library status information.

  For each item, adds `:in_library`, `:monitored`, and `:id` fields
  based on the library_status_map.
  """
  def enrich_with_library_status(items, library_status_map) do
    Enum.map(items, fn item ->
      provider_id_int =
        case item.provider_id do
          id when is_integer(id) -> id
          id when is_binary(id) -> String.to_integer(id)
          nil -> nil
        end

      library_status =
        Map.get(library_status_map, provider_id_int) ||
          Map.get(library_status_map, {:tvdb, provider_id_int}) ||
          %{in_library: false}

      Map.merge(item, %{
        in_library: library_status[:in_library] || false,
        monitored: library_status[:monitored] || false,
        id: library_status[:id]
      })
    end)
  end

  @doc """
  Builds media item attrs from metadata for creating a media item.

  ## Options
    * `:tmdb_id` - Explicit TMDB ID to use
    * `:tvdb_id` - Explicit TVDB ID to use
    * `:metadata_source` - Provenance to stamp (`:tvdb` | `:tmdb` | `nil`).
      Recorded for TV shows only; movies always leave it nil.
    * `:monitored` - Monitored flag for the new item (default: `true`)
    * `:quality_profile_id` - Quality profile to assign. Omitted from the attrs
      entirely when nil.

  If neither id is given, falls back to parsing `metadata.provider_id` as tmdb_id.
  """
  def build_media_item_attrs(metadata, media_type, opts \\ []) do
    type_string = if media_type == :movie, do: "movie", else: "tv_show"
    tmdb_id = opts[:tmdb_id]
    tvdb_id = opts[:tvdb_id]

    {tmdb_id, tvdb_id} =
      case {tmdb_id, tvdb_id} do
        {nil, nil} ->
          {parse_provider_id(metadata.provider_id), nil}

        other ->
          other
      end

    attrs = %{
      type: type_string,
      title: metadata.title,
      original_title: metadata.original_title,
      year: extract_year(metadata),
      tmdb_id: tmdb_id,
      tvdb_id: tvdb_id,
      imdb_id: metadata.imdb_id,
      metadata: metadata,
      monitored: Keyword.get(opts, :monitored, true)
    }

    attrs = maybe_put_quality_profile(attrs, opts[:quality_profile_id])

    # Record provenance for TV shows only; movies leave metadata_source nil.
    if media_type == :movie do
      attrs
    else
      Map.put(attrs, :metadata_source, opts[:metadata_source])
    end
  end

  defp maybe_put_quality_profile(attrs, nil), do: attrs
  defp maybe_put_quality_profile(attrs, id), do: Map.put(attrs, :quality_profile_id, id)

  @doc """
  Looks up TVDB ID for a TV show by searching TVDB by title+year.
  """
  def lookup_and_add_tvdb_id(attrs, config) do
    search_opts =
      if attrs[:year] do
        [media_type: :tv_show, provider: :tvdb, year: attrs[:year]]
      else
        [media_type: :tv_show, provider: :tvdb]
      end

    case Metadata.search(config, attrs.title, search_opts) do
      {:ok, [first | _]} ->
        case Integer.parse(first.provider_id) do
          {tvdb_id, ""} -> Map.put(attrs, :tvdb_id, tvdb_id)
          _ -> attrs
        end

      _ ->
        attrs
    end
  end

  @doc """
  Handles the full add-media-to-library flow.

  For TV shows, the metadata provider is derived from the configured
  `:series`/`:mixed` libraries (see `Settings.derive_tv_metadata_source/0`) and
  stamped as `metadata_source` so content, episodes, and provenance agree. When
  the libraries conflict, the item is added with `metadata_source: nil` and the
  scan path establishes provenance later.

  For movies, uses TMDB as the primary source and leaves `metadata_source` nil.

  Returns `{:ok, media_item, updated_library_status_map}` or `{:error, reason}`.

  An optional `config` (relay config map) can be injected for testing; it
  defaults to `Metadata.default_relay_config()`.

  `opts` are forwarded to `build_media_item_attrs/3`; `:monitored` and
  `:quality_profile_id` let a caller inherit settings from an item the user is
  already looking at. TV shows ignore them today.
  """
  def handle_add_media_to_library(
        provider_id,
        media_type,
        library_status_map,
        config \\ nil,
        opts \\ []
      ) do
    provider_id_int = parse_provider_id(provider_id)
    config = config || Metadata.default_relay_config()

    result =
      if media_type == :tv_show do
        add_tv_show_to_library(provider_id, provider_id_int, config)
      else
        add_movie_to_library(provider_id, provider_id_int, config, opts)
      end

    case result do
      {:ok, media_item} ->
        updated_map = update_library_status_map(library_status_map, media_item, provider_id_int)
        {:ok, media_item, updated_map}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Fetches detailed metadata for the detail modal.

  For TV shows, the preview reflects the provider the add flow will use: when
  the derived source is `:tmdb` the TMDB metadata is returned directly;
  otherwise it tries to resolve richer TVDB metadata, falling back to TMDB if
  that lookup fails.

  For movies, fetches TMDB metadata directly.

  An optional `config` can be injected for testing; defaults to
  `Metadata.default_relay_config()`.
  """
  def fetch_detail_metadata(tmdb_id, media_type, config \\ nil) do
    config = config || Metadata.default_relay_config()

    if media_type == :tv_show do
      case Metadata.fetch_by_id(config, tmdb_id, media_type: :tv_show, provider: :tmdb) do
        {:ok, tmdb_metadata} ->
          if Settings.derive_tv_metadata_source() == :tmdb do
            {:ok, tmdb_metadata}
          else
            case resolve_tvdb_metadata(tmdb_metadata, config) do
              {:ok, tvdb_metadata, _tvdb_id} -> {:ok, tvdb_metadata}
              {:error, _} -> {:ok, tmdb_metadata}
            end
          end

        error ->
          error
      end
    else
      Metadata.fetch_by_id(config, tmdb_id, media_type: :movie)
    end
  end

  @doc """
  Formats changeset errors into a human-readable string.
  """
  def format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc_msg ->
        String.replace(acc_msg, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  # Private helpers

  defp add_movie_to_library(provider_id, provider_id_int, config, opts) do
    case Metadata.fetch_by_id(config, provider_id, media_type: :movie, provider: :tmdb) do
      {:ok, metadata} ->
        attrs =
          build_media_item_attrs(
            metadata,
            :movie,
            Keyword.put(opts, :tmdb_id, provider_id_int)
          )

        case Media.create_media_item(attrs) do
          {:ok, media_item} -> {:ok, media_item}
          {:error, changeset} -> {:error, {:changeset, changeset}}
        end

      {:error, reason} ->
        {:error, {:metadata, reason}}
    end
  end

  defp add_tv_show_to_library(provider_id, provider_id_int, config) do
    # Derive the provider from the configured libraries. `derived` may be nil
    # (libraries disagree); the fetch still needs a provider, so fall back to
    # TVDB for content while leaving provenance unstamped.
    derived = Settings.derive_tv_metadata_source()
    fetch_provider = derived || :tvdb

    # Fetch TMDB metadata first (we have the TMDB ID from curated lists)
    case Metadata.fetch_by_id(config, provider_id, media_type: :tv_show, provider: :tmdb) do
      {:ok, tmdb_metadata} ->
        tmdb_metadata
        |> build_tv_show_attrs(provider_id_int, derived, fetch_provider, config)
        |> create_media_item_result()

      {:error, reason} ->
        {:error, {:metadata, reason}}
    end
  end

  # Derived source is TMDB: keep the TMDB metadata as primary, resolve a
  # secondary tvdb_id for dedup/future matching, and stamp :tmdb.
  defp build_tv_show_attrs(tmdb_metadata, provider_id_int, derived, :tmdb, config) do
    build_media_item_attrs(tmdb_metadata, :tv_show,
      tmdb_id: provider_id_int,
      metadata_source: derived
    )
    |> lookup_and_add_tvdb_id(config)
  end

  # Derived source is TVDB (or nil/conflict): use richer TVDB metadata as
  # primary when resolvable, else TMDB content with a tvdb_id from search.
  # Provenance is stamped as `derived` (:tvdb, or nil on conflict).
  defp build_tv_show_attrs(tmdb_metadata, provider_id_int, derived, :tvdb, config) do
    case resolve_tvdb_metadata(tmdb_metadata, config) do
      {:ok, tvdb_metadata, tvdb_id} ->
        build_media_item_attrs(tvdb_metadata, :tv_show,
          tmdb_id: provider_id_int,
          tvdb_id: tvdb_id,
          metadata_source: derived
        )

      {:error, _} ->
        build_media_item_attrs(tmdb_metadata, :tv_show,
          tmdb_id: provider_id_int,
          metadata_source: derived
        )
        |> lookup_and_add_tvdb_id(config)
    end
  end

  defp create_media_item_result(attrs) do
    case Media.create_media_item(attrs) do
      {:ok, media_item} -> {:ok, media_item}
      {:error, changeset} -> {:error, {:changeset, changeset}}
    end
  end

  defp resolve_tvdb_metadata(tmdb_metadata, config) do
    year = extract_year(tmdb_metadata)

    search_opts =
      if year do
        [media_type: :tv_show, provider: :tvdb, year: year]
      else
        [media_type: :tv_show, provider: :tvdb]
      end

    with {:ok, [first | _]} <- Metadata.search(config, tmdb_metadata.title, search_opts),
         {tvdb_id, ""} <- Integer.parse(first.provider_id),
         {:ok, tvdb_metadata} <-
           Metadata.fetch_by_id(config, to_string(tvdb_id),
             media_type: :tv_show,
             provider: :tvdb
           ) do
      {:ok, tvdb_metadata, tvdb_id}
    else
      _ -> {:error, :tvdb_not_found}
    end
  end

  defp update_library_status_map(library_status_map, media_item, tmdb_id_int) do
    entry = %{
      in_library: true,
      monitored: media_item.monitored,
      type: media_item.type,
      id: media_item.id
    }

    map = Map.put(library_status_map, tmdb_id_int, entry)

    if media_item.tvdb_id do
      Map.put(map, {:tvdb, media_item.tvdb_id}, entry)
    else
      map
    end
  end

  defp extract_year(metadata) do
    cond do
      metadata.year ->
        metadata.year

      metadata.release_date || metadata.first_air_date ->
        date_value = metadata.release_date || metadata.first_air_date
        extract_year_from_date(date_value)

      true ->
        nil
    end
  end

  defp extract_year_from_date(%Date{} = date), do: date.year

  defp extract_year_from_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date.year
      _ -> nil
    end
  end

  defp extract_year_from_date(_), do: nil

  defp parse_provider_id(nil), do: nil
  defp parse_provider_id(id) when is_integer(id), do: id
  defp parse_provider_id(id) when is_binary(id), do: String.to_integer(id)
end
