defmodule MydiaWeb.LibrarySchema.Resolvers.Lookup do
  @moduledoc """
  Resolves `lookup`: search the metadata relay, then say which hits are already
  in the library.

  `Mydia.Media.library_status_for_tmdb_ids/2` returns only the ids it found, so
  a miss is an absent key rather than a false. TVDB ids have no bulk lookup and
  fall back to `find_by_external_ids/2` one at a time.
  """

  require Logger

  alias Mydia.LibraryApi.RevisionFeed
  alias Mydia.Media
  alias Mydia.Metadata
  alias Mydia.Metadata.ImageUrl
  alias MydiaWeb.LibrarySchema.MediaItemView

  @providers [:tmdb, :tvdb]

  @spec lookup(any(), map(), Absinthe.Resolution.t()) :: {:ok, [map()]} | {:error, term()}
  def lookup(_parent, %{query: query, type: type} = args, _info) do
    opts =
      [media_type: type]
      |> maybe_put(:year, Map.get(args, :year))

    case Metadata.search_cached(Metadata.default_relay_config(), query, opts) do
      {:ok, results} ->
        build_results(results)

      {:error, reason} ->
        Logger.warning("Library API lookup failed: #{inspect(reason)}")

        {:error,
         %{message: "Metadata lookup failed", extensions: %{code: "METADATA_UNAVAILABLE"}}}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp build_results(results) do
    # A provider outside the enum cannot satisfy the non-null `provider` field.
    # Dropping the row keeps the rest of the search useful.
    usable =
      Enum.filter(results, fn result ->
        if result.provider in @providers do
          true
        else
          Logger.warning(
            "Library API lookup dropped a result from unsupported provider #{inspect(result.provider)}"
          )

          false
        end
      end)

    with {:ok, in_library} <- resolve_in_library(usable) do
      {:ok,
       Enum.map(usable, fn result ->
         %{
           provider: result.provider,
           provider_id: result.provider_id,
           type: result.media_type,
           title: result.title,
           year: result.year,
           overview: result.overview,
           poster_url: ImageUrl.poster_url(result.poster_path),
           imdb_id: result.imdb_id,
           in_library: Map.get(in_library, {result.provider, to_string(result.provider_id)})
         }
       end)}
    end
  end

  defp resolve_in_library(results) do
    {tmdb, tvdb} = Enum.split_with(results, &(&1.provider == :tmdb))

    tmdb
    |> tmdb_index()
    |> Map.merge(tvdb_index(tvdb))
    |> hydrate()
  end

  defp tmdb_index(results) do
    by_type =
      results
      |> Enum.group_by(& &1.media_type)
      |> Enum.map(fn {type, group} ->
        ids =
          group
          |> Enum.map(&parse_id(&1.provider_id))
          |> Enum.reject(&is_nil/1)

        {type, ids, group}
      end)

    Enum.reduce(by_type, %{}, fn {type, ids, group}, acc ->
      found = Media.library_status_for_tmdb_ids(ids, to_string(type))

      Enum.reduce(group, acc, fn result, acc ->
        case parse_id(result.provider_id) do
          nil ->
            acc

          id ->
            case Map.get(found, id) do
              nil -> acc
              %{id: item_id} -> Map.put(acc, {:tmdb, to_string(result.provider_id)}, item_id)
            end
        end
      end)
    end)
  end

  defp tvdb_index(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      case Media.find_by_external_ids(%{tvdb: result.provider_id},
             type: to_string(result.media_type)
           ) do
        nil -> acc
        item -> Map.put(acc, {:tvdb, to_string(result.provider_id)}, item.id)
      end
    end)
  end

  # The two indexes above answer with ids, because that is what a bulk lookup can
  # give. `inLibrary` is a MediaItem, so one batched fetch turns the whole set of
  # matches into hydrated items -- including the availability status, which needs
  # the media preloads or it reads the wrong thing. The aggregate timestamps come
  # from one more batch over the revision markers, tombstones included, never one
  # query per hit.
  defp hydrate(index) do
    ids = index |> Map.values() |> Enum.uniq()

    case ids do
      [] ->
        {:ok, %{}}

      ids ->
        found = Media.list_media_items(ids: ids, preload: MediaItemView.preloads())
        by_id = Map.new(found, &{&1.id, &1})

        with {:ok, changed_at_by_id} <- RevisionFeed.live_changed_at_by_ids(Map.keys(by_id)) do
          {:ok,
           Map.new(index, fn {key, id} -> {key, in_library_item(by_id, changed_at_by_id, id)} end)}
        end
    end
  end

  defp in_library_item(by_id, changed_at_by_id, id) do
    case Map.get(by_id, id) do
      nil ->
        nil

      item ->
        case Map.fetch!(changed_at_by_id, id) do
          nil -> nil
          changed_at -> MediaItemView.item_map(item, changed_at)
        end
    end
  end

  # Provider ids arrive as strings; the id columns are integers, and Ecto raises
  # rather than returning nil when an uncastable value reaches a query.
  defp parse_id(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} -> id
      _ -> nil
    end
  end
end
