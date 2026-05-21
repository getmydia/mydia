defmodule MydiaWeb.Schema.Resolvers.SearchResolver do
  @moduledoc """
  Resolvers for search-related GraphQL queries.
  """

  alias Mydia.Media
  alias MydiaWeb.Schema.Resolvers.MediaHelpers

  @spec search(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def search(_parent, %{query: query} = args, _info) when byte_size(query) > 0 do
    first = Map.get(args, :first, 20)
    types = Map.get(args, :types)
    include_external = Map.get(args, :include_external, false)

    # Build local query options
    local_opts = [search: query]

    local_opts =
      if types do
        type_filter =
          cond do
            :movie in types and :tv_show in types -> nil
            :movie in types -> "movie"
            :tv_show in types -> "tv_show"
            true -> nil
          end

        if type_filter, do: Keyword.put(local_opts, :type, type_filter), else: local_opts
      else
        local_opts
      end

    # Local results
    local_results =
      Media.list_media_items(local_opts)
      |> Enum.map(&build_search_result/1)

    # External results
    external_results =
      if include_external do
        search_types = types || [:movie, :tv_show]

        Enum.flat_map(search_types, fn type ->
          case Mydia.Metadata.search_cached(Mydia.Metadata.default_relay_config(), query,
                 media_type: type
               ) do
            {:ok, items} -> Enum.map(items, &MediaHelpers.map_external_to_search_result(&1, type))
            _ -> []
          end
        end)
      else
        []
      end

    # Merge and deduplicate by title/year or provider_id
    combined =
      (local_results ++ external_results)
      |> Enum.uniq_by(fn item ->
        # Deduplicate based on title and year (low fidelity but works for mixed sources)
        {String.downcase(item.title), item.year}
      end)
      |> Enum.take(first)

    {:ok,
     %{
       results: combined,
       total_count: length(combined)
     }}
  end

  def search(_parent, _args, _info) do
    {:ok, %{results: [], total_count: 0}}
  end

  defp build_search_result(media_item) do
    %{
      id: media_item.id,
      type: String.to_existing_atom(media_item.type),
      title: media_item.title,
      year: media_item.year,
      artwork: MediaHelpers.build_artwork(media_item),
      score: nil
    }
  end
end
