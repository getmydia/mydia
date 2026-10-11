defmodule Mydia.Indexers.Cardigann.JsonPath do
  @moduledoc """
  Navigates the JSONPath-like selectors that Cardigann definitions use against
  decoded JSON.

  The result parser needs this in two places, locating the rows of a response
  and reading a nested value out of a row, and it also has to evaluate the
  `rows.count` selector that tells it whether a response holds any releases at
  all. The selector dialect is a small subset of JSONPath (`$.a.b`, `a.b`,
  `items[0]`, `$["key-with-dashes"]`), so it lives here as a pure function over
  decoded data and keeps the parser focused on turning rows into results.
  """

  @doc """
  Walks `path` through decoded JSON.

  Returns `{:ok, value}`, `{:error, :path_not_found}` when a key or index is
  missing, or `{:error, :invalid_path}` when a step does not fit the value
  (for example a key applied to a scalar).
  """
  @spec navigate(term(), String.t()) :: {:ok, term()} | {:error, :path_not_found | :invalid_path}
  def navigate(json, "$"), do: {:ok, json}
  def navigate(json, "$."), do: {:ok, json}
  def navigate(json, "$." <> path), do: navigate_parts(json, String.split(path, "."))

  def navigate(json, path) do
    # Split dotted paths (e.g., "data.movies" → ["data", "movies"])
    navigate_parts(json, String.split(path, "."))
  end

  # Cardigann's JSON `rows.count` is a selector for the number of results, not a
  # row limit (the HTML and XML paths read an integer `count` as a limit, which
  # is a different key shape and stays untouched). Prowlarr returns no releases
  # when it evaluates below 1. apibay.org relies on this: a search with no hits
  # answers `[{"id":"0","name":"No results returned",...}]`, and without the
  # check that placeholder becomes a result with an all-zero info hash.
  @doc """
  Whether the definition's `rows.count` selector evaluates below 1 for `json`.
  """
  @spec reports_no_results?(term(), map()) :: boolean()
  def reports_no_results?(json, %{rows: row_config}) when is_map(row_config) do
    case Map.get(row_config, :count) do
      %{} = count ->
        selector = Map.get(count, "selector") || Map.get(count, :selector)
        is_binary(selector) and count_below_one?(count_value(json, selector))

      _ ->
        false
    end
  end

  def reports_no_results?(_json, _search_config), do: false

  # navigate/2 reads "$.0.id" but not "$[0].id", the form
  # definitions use for a leading array index.
  defp count_value(json, selector) do
    path = Regex.replace(~r/^\$\[(\d+)\]/, selector, "$.\\1")

    case navigate(json, path) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp count_below_one?(value) when is_integer(value), do: value < 1

  defp count_below_one?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n < 1
      _ -> false
    end
  end

  defp count_below_one?(_value), do: false

  defp navigate_parts(value, []) do
    {:ok, value}
  end

  defp navigate_parts(map, [key | rest]) when is_map(map) do
    # Handle bracket notation: key[N] for array indexing or ["key-with-dashes"]
    case parse_bracket_access(key) do
      {:index, base_key, index} ->
        # Access map key then array index: e.g., "items[0]"
        with value when not is_nil(value) <- Map.get(map, base_key),
             true <- is_list(value),
             item when not is_nil(item) <- Enum.at(value, index) do
          navigate_parts(item, rest)
        else
          _ -> {:error, :path_not_found}
        end

      {:quoted_key, quoted_key} ->
        # Bracket notation with quoted key: $["key-with-dashes"]
        case Map.get(map, quoted_key) do
          nil -> {:error, :path_not_found}
          value -> navigate_parts(value, rest)
        end

      :plain ->
        case Map.get(map, key) do
          nil -> {:error, :path_not_found}
          value -> navigate_parts(value, rest)
        end
    end
  end

  defp navigate_parts(list, [key | rest]) when is_list(list) do
    # Direct array index access
    case Integer.parse(key) do
      {index, ""} ->
        case Enum.at(list, index) do
          nil -> {:error, :path_not_found}
          value -> navigate_parts(value, rest)
        end

      _ ->
        {:error, :invalid_path}
    end
  end

  defp navigate_parts(_value, _path) do
    {:error, :invalid_path}
  end

  # Parses bracket access notation in JSON path keys
  defp parse_bracket_access(key) do
    cond do
      # key[N] pattern - array index on a map value
      Regex.match?(~r/^(.+)\[(\d+)\]$/, key) ->
        [_, base_key, idx_str] = Regex.run(~r/^(.+)\[(\d+)\]$/, key)
        {:index, base_key, String.to_integer(idx_str)}

      # ["key"] or ['key'] pattern - quoted key access
      Regex.match?(~r/^\[["'](.+?)["']\]$/, key) ->
        [_, quoted_key] = Regex.run(~r/^\[["'](.+?)["']\]$/, key)
        {:quoted_key, quoted_key}

      true ->
        :plain
    end
  end
end
