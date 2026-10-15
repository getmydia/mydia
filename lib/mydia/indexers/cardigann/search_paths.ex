defmodule Mydia.Indexers.Cardigann.SearchPaths do
  @moduledoc """
  Which of a Cardigann definition's `search.paths` a query runs.

  Definitions paginate by listing one path per page, and scope paths to
  categories. Prowlarr's `CardigannRequestGenerator` runs every path whose
  categories match the query, and this is that rule:

  - a query with no categories runs every path;
  - a path with no `categories` always runs;
  - a path's `categories` are site ids, mapped to Torznab through the
    definition's `categorymappings`; one matches when its Torznab id, or that
    id's parent, is among the query's categories;
  - a list starting with `"!"` inverts the match;
  - when nothing matches, the first path runs.
  """

  alias Mydia.Indexers.CategoryMapping

  @spec matching([map()], [integer()], list()) :: [map()]
  def matching([], _query_categories, _mappings), do: []

  def matching([first | _] = paths, query_categories, mappings) do
    case Enum.filter(paths, &runs?(&1, query_categories, mappings)) do
      [] -> [first]
      matched -> matched
    end
  end

  defp runs?(_path, [], _mappings), do: true

  defp runs?(path, query_categories, mappings) do
    case path |> Map.get(:categories) |> List.wrap() |> Enum.map(&to_string/1) do
      [] -> true
      ["!" | site_ids] -> not any_match?(site_ids, query_categories, mappings)
      site_ids -> any_match?(site_ids, query_categories, mappings)
    end
  end

  defp any_match?(site_ids, query_categories, mappings) do
    Enum.any?(site_ids, fn site_id ->
      case CategoryMapping.map_site_category_to_torznab(site_id, mappings) do
        nil -> false
        torznab -> torznab in query_categories or parent(torznab) in query_categories
      end
    end)
  end

  defp parent(torznab), do: div(torznab, 1000) * 1000
end
