defmodule Mydia.Indexers.Cardigann.Result.Format.Json do
  @moduledoc false
  # JSON adapter. Behaviour is a port of the JSON helpers in
  # `CardigannResultParser`, plus what the shared extractor needs: charset
  # decoding of binary bodies, already-decoded documents, scalar rows skipped
  # instead of raising, and `case`.

  @behaviour Mydia.Indexers.Cardigann.Result.Format

  require Logger

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.Cardigann.JsonPath
  alias Mydia.Indexers.Cardigann.Result.Format.Template
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.Rows

  @impl true
  def document(body, %Plan{} = plan) when is_binary(body) do
    body |> Charset.decode(plan.encoding) |> Jason.decode()
  end

  # The map variant of the entry point hands over a body that is already decoded.
  def document(json, %Plan{}) when is_map(json) or is_list(json), do: {:ok, json}
  def document(_other, %Plan{}), do: {:error, :invalid_body}

  @impl true
  def rows(document, %Rows{selector: selector, attribute: attribute}) do
    case JsonPath.navigate(document, selector) do
      {:ok, rows} when is_list(rows) ->
        rows |> maybe_expand_attribute(attribute) |> Enum.filter(&is_map/1)

      {:ok, single} when is_map(single) ->
        [single]

      {:ok, _scalar} ->
        []

      {:error, :path_not_found} ->
        available = if is_map(document), do: Map.keys(document), else: []

        Logger.warning(
          "JSON path not found: #{selector}. Available top-level keys: #{inspect(available)}"
        )

        []

      # A selector the response's shape cannot satisfy (an index into a map, a
      # key into a scalar) is a definition/response mismatch, not an empty page.
      {:error, reason} ->
        {:error,
         "JSON row selector #{inspect(selector)} does not apply to the response: #{inspect(reason)}"}
    end
  end

  @impl true
  def raw(_document, row, field, opts \\ []) do
    case field.selector do
      selector when is_binary(selector) -> value_by_selector(row, Template.render(selector, opts))
      _ -> :not_found
    end
  end

  # Prowlarr's `HandleJsonSelector` compares each case key with the extracted
  # value by equality, in definition order, and `*` matches even when nothing
  # was extracted. `remove` and `attribute` do not apply to JSON. Values are
  # compared as strings, so a numeric 720 matches the key "720". Prowlarr's
  # ToString would give "True" for a boolean; `ensure_string/1` treats booleans
  # as not found here, so a boolean never matches a specific key.
  @impl true
  def case_value(document, row, field, opts \\ []) do
    value =
      case raw(document, row, field, opts) do
        {:ok, string} -> string
        :not_found -> nil
      end

    field.case
    |> Enum.find_value(fn {key, result} ->
      if key == "*" or (value != nil and value == Template.render(key, opts)), do: result
    end)
    |> case do
      nil -> :not_found
      result -> {:ok, result}
    end
  end

  # With `rows.attribute` set (e.g. "torrents"), each sub-item becomes its own
  # row carrying its parent under "__parent" so `..` selectors can reach it.
  defp maybe_expand_attribute(rows, attribute) when attribute in [nil, ""], do: rows

  defp maybe_expand_attribute(rows, attribute) do
    Enum.flat_map(rows, fn
      parent when is_map(parent) -> expand_parent(parent, attribute)
      _scalar -> []
    end)
  end

  defp expand_parent(parent, attribute) do
    case Map.get(parent, attribute) do
      sub_items when is_list(sub_items) ->
        for sub_item <- sub_items, is_map(sub_item), do: Map.put(sub_item, "__parent", parent)

      # Prowlarr's row is `row.SelectToken(attribute)`: an object names the row
      # itself (UNIT3D's `attributes`).
      %{} = sub_item ->
        [Map.put(sub_item, "__parent", parent)]

      _ ->
        [parent]
    end
  end

  # ".." reads a field of the parent object set by `maybe_expand_attribute/2`.
  defp value_by_selector(row, ".." <> parent_selector) do
    case Map.get(row, "__parent") do
      %{} = parent -> parent |> Map.get(parent_selector) |> ensure_string()
      _ -> :not_found
    end
  end

  defp value_by_selector(row, selector) do
    case Map.get(row, selector) do
      nil ->
        with true <- String.contains?(selector, "."),
             {:ok, value} <- JsonPath.navigate(row, selector) do
          ensure_string(value)
        else
          _ -> :not_found
        end

      value ->
        ensure_string(value)
    end
  end

  defp ensure_string(value) when is_binary(value), do: {:ok, value}
  defp ensure_string(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp ensure_string(value) when is_float(value), do: {:ok, Float.to_string(value)}
  defp ensure_string(_other), do: :not_found
end
