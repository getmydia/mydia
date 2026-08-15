defmodule Mydia.Media.Add do
  @moduledoc """
  Turns a provider ID into a library media item.

  This is the single path from "the user picked something on TMDB or TVDB" to a
  row in `media_items` carrying full metadata. The admin "Add to Library" flow
  reaches it through `MydiaWeb.Live.Helpers.MediaAddHelpers`, and request
  approval reaches it through `Mydia.MediaRequests.approve_request/3`, so an
  approved request lands with the same poster, overview and provenance an
  admin-added item gets.

  `resolve_attrs/4` and `from_attrs/3` are separate so a caller can do the
  network work outside a database transaction and the insert inside one.
  """

  require Logger

  alias Mydia.Media
  alias Mydia.Media.ExternalIds
  alias Mydia.Metadata
  alias Mydia.Settings

  # Options consumed by `Media.create_media_item/2` rather than by attrs building.
  @create_opt_keys [:actor_type, :actor_id, :skip_episode_refresh, :season_monitoring]

  @type error ::
          {:metadata, term()}
          | {:changeset, Ecto.Changeset.t()}
          | {:already_in_library, Media.MediaItem.t()}

  @doc """
  Fetches provider metadata and builds the attrs for `Media.create_media_item/2`.

  Performs every network call this module makes, so callers that need to keep
  HTTP out of a database transaction can run this first.

  ## Options

    * `:provider` - `:tmdb` (default) or `:tvdb`. `:tvdb` is only meaningful for
      TV shows and fetches the TVDB series directly rather than starting from a
      TMDB lookup.
    * Everything `build_media_item_attrs/3` accepts.
  """
  @spec resolve_attrs(String.t() | integer(), :movie | :tv_show, map() | nil, keyword()) ::
          {:ok, map()} | {:error, {:metadata, term()}}
  def resolve_attrs(provider_id, media_type, config \\ nil, opts \\ [])

  def resolve_attrs(nil, _media_type, _config, _opts), do: {:error, {:metadata, :no_provider_id}}

  def resolve_attrs(provider_id, media_type, config, opts) do
    config = config || Metadata.default_relay_config()
    provider_id_int = parse_provider_id(provider_id)
    provider_id = to_string(provider_id_int)

    if media_type == :tv_show do
      resolve_tv_show_attrs(provider_id, provider_id_int, config, opts)
    else
      resolve_movie_attrs(provider_id, provider_id_int, config, opts)
    end
  end

  @doc """
  Inserts a media item from attrs produced by `resolve_attrs/4`.

  Makes no provider calls of its own. Note that `Media.create_media_item/2`
  still fetches episodes for TV shows, which is a network call; that is
  pre-existing behaviour and is deliberately left where it is.
  """
  @spec from_attrs(map(), map() | nil, keyword()) ::
          {:ok, Media.MediaItem.t()}
          | {:error,
             {:changeset, Ecto.Changeset.t()} | {:already_in_library, Media.MediaItem.t()}}
  def from_attrs(attrs, config \\ nil, opts \\ []) do
    config = config || Metadata.default_relay_config()

    case existing_item(attrs) do
      nil -> insert_media_item(attrs, config, opts)
      item -> {:error, {:already_in_library, backfill_ids(item, attrs)}}
    end
  end

  defp insert_media_item(attrs, config, opts) do
    create_opts =
      opts
      |> Keyword.take(@create_opt_keys)
      |> Keyword.put(:config, config)

    case Media.create_media_item(attrs, create_opts) do
      {:ok, media_item} -> {:ok, media_item}
      {:error, changeset} -> {:error, {:changeset, changeset}}
    end
  end

  # The unique indexes on tmdb_id and tvdb_id turn "you already have this" into
  # a changeset error the user reads as a bug. Look first, so the caller can
  # say something true instead.
  #
  # Two passes, because the attrs are not the whole story. A cross-referenced
  # id is dropped rather than carried: `ExternalIds.put_free_ids/3` leaves
  # `attrs[:tvdb_id]` nil precisely when another row already owns it, and the
  # title-search fallback in `lookup_and_add_tvdb_id/2` can then fill the empty
  # slot with a different, free id. Either way the attrs no longer mention the
  # taken id, while `metadata.external_ids` still does -- and the row holding
  # it is the collision. Without the second pass an add of a show already in
  # the library inserts a duplicate instead of reporting the incumbent.
  #
  # `:imdb` is deliberately absent from both passes. `imdb_id` carries no
  # unique index, so an imdb match can never be the constraint error this
  # pre-flight exists to pre-empt, and `find_by_external_ids/2`'s imdb leg
  # over-matches: TVDB's `remoteIds` hands split and spin-off series a shared
  # imdb id, which would turn a legitimate add into a false "already in your
  # library" and let `backfill_ids/2` stamp one title's provider id onto the
  # other. Every row Add or the scan path creates carries a tmdb or tvdb id, so
  # declining the imdb leg here costs no coverage.
  defp existing_item(attrs) do
    xrefs = metadata_external_ids(attrs)

    Enum.find_value(
      [
        %{tmdb: attrs[:tmdb_id], tvdb: attrs[:tvdb_id]},
        %{tmdb: xrefs[:tmdb], tvdb: xrefs[:tvdb]}
      ],
      &find_by_ids(&1, attrs[:type])
    )
  end

  defp find_by_ids(ids, type) do
    if Enum.all?(Map.values(ids), &is_nil/1) do
      nil
    else
      Media.find_by_external_ids(ids, type: type)
    end
  end

  # `attrs[:metadata]` is a `%MediaMetadata{}` when it came from
  # `build_media_item_attrs/3`, and absent entirely when a caller hand-built
  # the attrs. `external_ids` itself is nil on metadata written before
  # cross-provider ids were stored.
  defp metadata_external_ids(attrs) do
    case attrs[:metadata] do
      %{external_ids: ids} when is_map(ids) -> ids
      _ -> %{}
    end
  end

  # The existing row is usually the one missing an id, which is exactly why it
  # was not recognised. Fill what is free so the gap closes for good.
  #
  # The two providers are read from different places on purpose. `tmdb_id` in
  # the attrs is the id the user actually picked on Discover, or the exact
  # cross-reference TVDB published under `remoteIds`; either way it is not a
  # guess. `tvdb_id` can be one: when TMDB carries no cross-reference,
  # `lookup_and_add_tvdb_id/2` fills the slot from a TVDB title-and-year search
  # that takes the first hit on faith. Guessing is acceptable for the row we
  # are about to create -- nothing else claims it -- and not for a row that
  # already exists, where a wrong tvdb_id sends every later refresh to the
  # wrong series. So only the id `metadata.external_ids` cross-references is
  # persisted here. A row left without one is picked up by
  # `Mydia.Jobs.MetadataBackfill`, which refreshes it from its own provider.
  defp backfill_ids(item, attrs) do
    xrefs = metadata_external_ids(attrs)

    merged =
      %{tmdb_id: item.tmdb_id, tvdb_id: item.tvdb_id}
      |> ExternalIds.put_free_ids(%{tmdb: attrs[:tmdb_id], tvdb: xrefs[:tvdb]},
        exclude_id: item.id,
        title: item.title
      )

    changes =
      merged
      |> Enum.reject(fn {key, value} -> Map.get(item, key) == value end)
      |> Map.new()

    if changes == %{} do
      item
    else
      case Media.update_media_item(item, changes, reason: "Cross-referenced provider id") do
        {:ok, updated} -> updated
        {:error, _reason} -> item
      end
    end
  end

  @doc """
  Fetches metadata and creates the media item in one call.

  For TV shows the metadata provider is derived from the configured
  `:series`/`:mixed` libraries (see `Settings.derive_tv_metadata_source/0`) and
  stamped as `metadata_source` so content, episodes and provenance agree. When
  the libraries conflict the item is added with `metadata_source: nil` and the
  scan path establishes provenance later. Movies use TMDB and leave
  `metadata_source` nil.
  """
  @spec from_provider(String.t() | integer(), :movie | :tv_show, map() | nil, keyword()) ::
          {:ok, Media.MediaItem.t()} | {:error, error()}
  def from_provider(provider_id, media_type, config \\ nil, opts \\ []) do
    config = config || Metadata.default_relay_config()

    with {:ok, attrs} <- resolve_attrs(provider_id, media_type, config, opts) do
      from_attrs(attrs, config, opts)
    end
  end

  @doc """
  Builds media item attrs from metadata.

  ## Options
    * `:tmdb_id` - Explicit TMDB ID to use
    * `:tvdb_id` - Explicit TVDB ID to use
    * `:metadata_source` - Provenance to stamp (`:tvdb` | `:tmdb` | `nil`).
      Recorded for TV shows only; movies always leave it nil.
    * `:monitored` - Monitored flag for the new item (default: `true`)
    * `:quality_profile_id` - Quality profile to assign. Omitted from the attrs
      entirely when nil.
    * `:library_path_id` - Explicit target library. Omitted from the attrs
      entirely when nil, leaving the item on dynamic resolution.

  If neither id is given, falls back to parsing `metadata.provider_id` as tmdb_id.
  """
  def build_media_item_attrs(metadata, media_type, opts \\ []) do
    type_string = if media_type == :movie, do: "movie", else: "tv_show"
    tmdb_id = opts[:tmdb_id]
    tvdb_id = opts[:tvdb_id]

    {tmdb_id, tvdb_id} =
      case {tmdb_id, tvdb_id} do
        {nil, nil} -> {parse_provider_id(metadata.provider_id), nil}
        other -> other
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
    attrs = maybe_put_library_path(attrs, opts[:library_path_id])

    # Record provenance for TV shows only; movies leave metadata_source nil.
    attrs =
      if media_type == :movie do
        attrs
      else
        Map.put(attrs, :metadata_source, opts[:metadata_source])
      end

    ExternalIds.put_free_ids(attrs, metadata.external_ids)
  end

  @doc """
  Looks up a TVDB ID for a TV show by searching TVDB by title and year.

  A `tvdb_id` already present in the attrs was resolved exactly, from TMDB's
  `external_ids`, so it wins over anything this title search would find.
  """
  def lookup_and_add_tvdb_id(%{tvdb_id: tvdb_id} = attrs, _config) when not is_nil(tvdb_id),
    do: attrs

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
  Resolves richer TVDB metadata for a show discovered on TMDB.

  TMDB publishes the TVDB id under `external_ids`, so prefer that exact
  mapping. The title and year search below is the fallback for the shows TMDB
  does not cross-reference; it takes the first hit on faith, which is how a
  show can be resolved onto an id another row already owns.
  """
  def resolve_tvdb_metadata(tmdb_metadata, config) do
    case tvdb_id_from_metadata(tmdb_metadata) do
      nil -> resolve_tvdb_metadata_by_search(tmdb_metadata, config)
      tvdb_id -> fetch_tvdb_series(tvdb_id, config)
    end
  end

  defp tvdb_id_from_metadata(%{external_ids: %{tvdb: tvdb_id}}) when is_integer(tvdb_id),
    do: tvdb_id

  defp tvdb_id_from_metadata(_), do: nil

  defp fetch_tvdb_series(tvdb_id, config) do
    case Metadata.fetch_by_id(config, to_string(tvdb_id), media_type: :tv_show, provider: :tvdb) do
      {:ok, tvdb_metadata} -> {:ok, tvdb_metadata, tvdb_id}
      {:error, _reason} -> {:error, :tvdb_not_found}
    end
  end

  defp resolve_tvdb_metadata_by_search(tmdb_metadata, config) do
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

  @doc """
  Normalises a provider ID to an integer.
  """
  def parse_provider_id(nil), do: nil
  def parse_provider_id(id) when is_integer(id), do: id
  def parse_provider_id(id) when is_binary(id), do: String.to_integer(id)

  # Private helpers

  defp resolve_movie_attrs(provider_id, provider_id_int, config, opts) do
    case Metadata.fetch_by_id(config, provider_id, media_type: :movie, provider: :tmdb) do
      {:ok, metadata} ->
        {:ok,
         build_media_item_attrs(metadata, :movie, Keyword.put(opts, :tmdb_id, provider_id_int))}

      {:error, reason} ->
        {:error, {:metadata, reason}}
    end
  end

  defp resolve_tv_show_attrs(provider_id, provider_id_int, config, opts) do
    case Keyword.get(opts, :provider, :tmdb) do
      :tvdb -> resolve_tv_show_attrs_from_tvdb(provider_id, provider_id_int, config, opts)
      _ -> resolve_tv_show_attrs_from_tmdb(provider_id, provider_id_int, config, opts)
    end
  end

  # The request flow can hold a TVDB ID with no TMDB counterpart. Starting from
  # a TMDB lookup would send the TVDB id to the wrong provider.
  defp resolve_tv_show_attrs_from_tvdb(provider_id, provider_id_int, config, opts) do
    case Metadata.fetch_by_id(config, to_string(provider_id),
           media_type: :tv_show,
           provider: :tvdb
         ) do
      {:ok, tvdb_metadata} ->
        {:ok,
         build_media_item_attrs(
           tvdb_metadata,
           :tv_show,
           Keyword.merge(opts, tvdb_id: provider_id_int, metadata_source: :tvdb)
         )}

      {:error, reason} ->
        {:error, {:metadata, reason}}
    end
  end

  defp resolve_tv_show_attrs_from_tmdb(provider_id, provider_id_int, config, opts) do
    # The initial fetch below is always TMDB, because that is the id we hold.
    # `primary_provider` selects which provider's metadata ends up as the
    # item's primary content, not which one is fetched first. `derived` may be
    # nil when the configured libraries disagree; TVDB is the richer source, so
    # it wins the content while provenance stays unstamped.
    derived = Settings.derive_tv_metadata_source()
    primary_provider = derived || :tvdb

    case Metadata.fetch_by_id(config, provider_id, media_type: :tv_show, provider: :tmdb) do
      {:ok, tmdb_metadata} ->
        {:ok,
         build_tv_show_attrs(
           tmdb_metadata,
           provider_id_int,
           derived,
           primary_provider,
           config,
           opts
         )}

      {:error, reason} ->
        {:error, {:metadata, reason}}
    end
  end

  # Derived source is TMDB: keep the TMDB metadata as primary, resolve a
  # secondary tvdb_id for dedup/future matching, and stamp :tmdb.
  defp build_tv_show_attrs(tmdb_metadata, provider_id_int, derived, :tmdb, config, opts) do
    build_media_item_attrs(
      tmdb_metadata,
      :tv_show,
      Keyword.merge(opts, tmdb_id: provider_id_int, metadata_source: derived)
    )
    |> lookup_and_add_tvdb_id(config)
  end

  # Derived source is TVDB (or nil/conflict): use richer TVDB metadata as
  # primary when resolvable, else TMDB content with a tvdb_id from search.
  # Provenance is stamped as `derived` (:tvdb, or nil on conflict).
  defp build_tv_show_attrs(tmdb_metadata, provider_id_int, derived, :tvdb, config, opts) do
    case resolve_tvdb_metadata(tmdb_metadata, config) do
      {:ok, tvdb_metadata, tvdb_id} ->
        build_media_item_attrs(
          tvdb_metadata,
          :tv_show,
          Keyword.merge(opts,
            tmdb_id: provider_id_int,
            tvdb_id: tvdb_id,
            metadata_source: derived
          )
        )

      {:error, _} ->
        build_media_item_attrs(
          tmdb_metadata,
          :tv_show,
          Keyword.merge(opts, tmdb_id: provider_id_int, metadata_source: derived)
        )
        |> lookup_and_add_tvdb_id(config)
    end
  end

  defp maybe_put_quality_profile(attrs, nil), do: attrs
  defp maybe_put_quality_profile(attrs, id), do: Map.put(attrs, :quality_profile_id, id)

  defp maybe_put_library_path(attrs, nil), do: attrs
  defp maybe_put_library_path(attrs, id), do: Map.put(attrs, :library_path_id, id)

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
end
