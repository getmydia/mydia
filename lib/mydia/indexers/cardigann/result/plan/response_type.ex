defmodule Mydia.Indexers.Cardigann.Result.Plan.ResponseType do
  @moduledoc false
  # Resolves the response type a definition declares for the search path in
  # play. `nil` means the definition says nothing and the body has to be
  # sniffed. A path-declared `response.type` is authoritative.

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchEngine

  @search_opts [
    :categories,
    :config,
    :settings,
    :query,
    :season,
    :episode,
    :imdb_id,
    :tmdb_id,
    :base_url
  ]

  @spec declared(Parsed.t(), keyword()) :: :html | :json | :xml | nil
  def declared(%Parsed{} = definition, opts) do
    definition |> resolve_search_path(opts) |> declared_type() |> to_format()
  end

  defp resolve_search_path(definition, opts) do
    case Keyword.get(opts, :search_path) do
      path when is_map(path) -> path
      _ -> select_path(definition, opts)
    end
  end

  defp select_path(definition, opts) do
    paths = get_in(definition.search, [:paths]) || get_in(definition.search, ["paths"])

    if is_list(paths) and paths != [] do
      search_opts =
        opts
        |> Keyword.take(@search_opts)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case CardigannSearchEngine.select_search_path(definition, search_opts) do
        {:ok, path} -> path
        {:error, _} -> nil
      end
    end
  end

  defp declared_type(nil), do: nil

  defp declared_type(path) when is_map(path) do
    get_in(path, [:response, :type]) ||
      get_in(path, [:response, "type"]) ||
      get_in(path, ["response", :type]) ||
      get_in(path, ["response", "type"])
  end

  defp to_format("xml"), do: :xml
  defp to_format("json"), do: :json
  defp to_format("html"), do: :html
  defp to_format(_), do: nil
end
