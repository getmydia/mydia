defmodule MydiaWeb.Live.Helpers.MediaAddHelpers do
  @moduledoc """
  Shared LiveView helpers for the "Add to Library" flow.

  Used by DashboardLive, DiscoverLive and the media detail franchise panel.
  The actual provider-fetch-and-create work lives in `Mydia.Media.Add`, which
  request approval shares.
  """

  alias Mydia.Media.Add
  alias Mydia.Metadata
  alias Mydia.Settings

  @doc """
  Libraries a caller may pick as the add-time target for `media_type`.

  Filters to monitored, type-compatible libraries and drops unmaterialised
  runtime entries: those carry synthetic "runtime::" ids and have no
  `library_paths` row for a foreign key to reference. `LibraryPathSync` upserts
  env-configured paths into real rows at startup, so this list is complete in
  practice.
  """
  @spec candidate_libraries(:movie | :tv_show) :: [Mydia.Settings.LibraryPath.t()]
  def candidate_libraries(media_type) do
    kind = if media_type == :movie, do: :movies, else: :series
    allowed = Mydia.Library.TargetResolver.allowed_types(kind)

    Settings.list_library_paths()
    |> Enum.filter(fn lp ->
      lp.type in allowed and lp.monitored and
        not String.starts_with?(to_string(lp.id), "runtime::")
    end)
  end

  @doc """
  Enriches a list of search result items with library status information.

  For each item, adds `:in_library`, `:monitored`, and `:id` fields
  based on the library_status_map.
  """
  def enrich_with_library_status(items, library_status_map) do
    Enum.map(items, fn item ->
      provider_id_int = Add.parse_provider_id(item.provider_id)

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
  Builds media item attrs from metadata. See `Mydia.Media.Add.build_media_item_attrs/3`.
  """
  defdelegate build_media_item_attrs(metadata, media_type, opts \\ []), to: Add

  @doc """
  Handles the full add-media-to-library flow.

  Returns `{:ok, media_item, updated_library_status_map}`,
  `{:already_in_library, media_item, updated_library_status_map}`, or
  `{:error, reason}`, where reason is `{:metadata, term()}` or
  `{:changeset, Ecto.Changeset.t()}`.

  The `:already_in_library` tuple is not an error from a caller's point of
  view: the show the user asked for is in the library, just under a row that
  was already there. Callers should flash it as info rather than an error.

  An optional `config` (relay config map) can be injected for testing; it
  defaults to `Metadata.default_relay_config()`.

  `opts` are forwarded to `Mydia.Media.Add`; `:monitored`,
  `:quality_profile_id` and `:library_path_id` let a caller inherit settings
  from an item the user is already looking at, or pin an explicit target
  library. TV shows ignore monitored and quality profile today.
  """
  def handle_add_media_to_library(
        provider_id,
        media_type,
        library_status_map,
        config \\ nil,
        opts \\ []
      ) do
    provider_id_int = Add.parse_provider_id(provider_id)

    case Add.from_provider(provider_id, media_type, config, opts) do
      {:ok, media_item} ->
        {:ok, media_item,
         update_library_status_map(library_status_map, media_item, provider_id_int)}

      # Not an error from here up: the show the user asked for is in the
      # library. Callers flash it as info and flip the card.
      {:error, {:already_in_library, media_item}} ->
        {:already_in_library, media_item,
         update_library_status_map(library_status_map, media_item, provider_id_int)}

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
            case Add.resolve_tvdb_metadata(tmdb_metadata, config) do
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
end
