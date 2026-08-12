defmodule Mydia.Indexers.Cardigann.Features do
  @moduledoc """
  Registry of Cardigann definition features and static detection of required features.

  A feature appears in `@supported` only when there is a fixture exercising it.
  That invariant is enforced by the registry-to-fixture consistency test in Task 19.
  """

  @supported [
    :field_selector,
    :field_attribute,
    :field_text,
    :field_optional,
    :field_remove,
    :field_default,
    :field_case,
    :rows_after,
    :rows_count,
    :response_html,
    :response_json,
    :response_xml,
    :keywordsfilters,
    :allow_empty_inputs,
    :download_selectors,
    :download_infohash,
    :download_before,
    :legacylinks
  ]

  @doc """
  Returns the list of features implemented by the native Cardigann engine.
  """
  @spec supported() :: [atom()]
  def supported, do: @supported

  @doc """
  Walks a decoded YAML definition map and returns the set of features it requires.
  """
  @spec required(map()) :: MapSet.t(atom())
  def required(yaml) when is_map(yaml) do
    []
    |> add_legacylinks(yaml)
    |> add_download(yaml)
    |> add_login(yaml)
    |> add_search(yaml)
    |> MapSet.new()
  end

  defp add_legacylinks(acc, yaml) do
    case Map.get(yaml, "legacylinks", []) do
      [_ | _] -> [:legacylinks | acc]
      _ -> acc
    end
  end

  defp add_download(acc, yaml) do
    case Map.get(yaml, "download") do
      download when is_map(download) ->
        acc
        |> maybe_add(:download_selectors, present_list_or_map?(Map.get(download, "selectors")))
        |> maybe_add(:download_infohash, is_map(Map.get(download, "infohash")))
        |> maybe_add(:download_before, present_list_or_map?(Map.get(download, "before")))

      _ ->
        acc
    end
  end

  defp add_login(acc, yaml) do
    case Map.get(yaml, "login") do
      login when is_map(login) ->
        acc
        |> maybe_add(:login_captcha, is_map(Map.get(login, "captcha")))
        |> maybe_add(
          :login_selectorinputs,
          present_list_or_map?(Map.get(login, "selectorinputs"))
        )
        |> maybe_add(:login_cookies, present_list_or_map?(Map.get(login, "cookies")))
        |> maybe_add(:login_submitpath, Map.has_key?(login, "submitpath"))
        |> maybe_add(:login_selectors, present_list_or_map?(Map.get(login, "selectors")))

      _ ->
        acc
    end
  end

  defp add_search(acc, yaml) do
    search = Map.get(yaml, "search", %{})

    acc
    |> maybe_add(:keywordsfilters, present_list_or_map?(Map.get(search, "keywordsfilters")))
    |> maybe_add(:allow_empty_inputs, Map.get(search, "allowEmptyInputs") == true)
    |> add_rows(Map.get(search, "rows"))
    |> add_fields(Map.get(search, "fields", %{}))
    |> add_response_types(search)
  end

  defp add_rows(acc, rows) when is_map(rows) do
    acc
    |> maybe_add(:rows_after, Map.has_key?(rows, "after"))
    |> maybe_add(:rows_count, Map.has_key?(rows, "count"))
    |> maybe_add(:rows_multiple, Map.get(rows, "multiple") == true)
    |> maybe_add(
      :rows_missing_attribute_equals_no_results,
      Map.get(rows, "missingAttributeEqualsNoResults") == true
    )
  end

  defp add_rows(acc, _), do: acc

  defp add_fields(acc, fields) when is_map(fields) do
    Enum.reduce(fields, acc, fn {_name, field}, acc ->
      if is_map(field) do
        acc
        |> maybe_add(:field_selector, Map.has_key?(field, "selector"))
        |> maybe_add(:field_attribute, Map.has_key?(field, "attribute"))
        |> maybe_add(:field_text, Map.has_key?(field, "text"))
        |> maybe_add(:field_optional, Map.get(field, "optional") == true)
        |> maybe_add(:field_remove, Map.has_key?(field, "remove"))
        |> maybe_add(:field_default, Map.has_key?(field, "default"))
        |> maybe_add(:field_case, Map.has_key?(field, "case"))
      else
        acc
      end
    end)
  end

  defp add_fields(acc, _), do: acc

  defp add_response_types(acc, search) do
    paths =
      case Map.get(search, "paths") do
        paths when is_list(paths) -> paths
        _ -> if path = Map.get(search, "path"), do: [%{"path" => path}], else: []
      end

    types =
      paths
      |> Enum.map(fn path ->
        case get_in(path, ["response", "type"]) do
          nil -> "html"
          type -> type
        end
      end)
      |> Enum.uniq()

    Enum.reduce(types, acc, fn type, acc ->
      case type do
        "json" -> [:response_json | acc]
        "xml" -> [:response_xml | acc]
        _ -> [:response_html | acc]
      end
    end)
  end

  defp maybe_add(acc, feature, true), do: [feature | acc]
  defp maybe_add(acc, _feature, _), do: acc

  defp present_list_or_map?(nil), do: false
  defp present_list_or_map?([]), do: false
  defp present_list_or_map?(%{}), do: false
  defp present_list_or_map?(_), do: true
end
