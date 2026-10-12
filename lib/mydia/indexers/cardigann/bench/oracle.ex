defmodule Mydia.Indexers.Cardigann.Bench.Oracle do
  @moduledoc """
  Minimal client for a Prowlarr instance used as the benchmark oracle.

  Dev tooling: it holds no state, starts nothing and reads no config. The base
  URL and API key are arguments. Endpoints and field names follow Prowlarr
  v2.6.5.5623: `Prowlarr.Api.V1/Indexers/IndexerResource.cs`,
  `Prowlarr.Api.V1/Search/SearchResource.cs` and `ReleaseResource.cs`.
  """

  alias Mydia.Indexers.Cardigann.Bench.Release

  defstruct [:base_url, :api_key, req_options: []]

  @type t :: %__MODULE__{base_url: String.t(), api_key: String.t(), req_options: keyword()}

  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(base_url, api_key, req_options \\ []) do
    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      api_key: api_key,
      req_options: req_options
    }
  end

  @doc """
  Returns the id of the indexer for `definition_name`, creating it from
  Prowlarr's schema (with `settings` filled into `fields`) when absent.
  """
  @spec ensure_indexer(t(), String.t(), map()) :: {:ok, integer()} | {:error, term()}
  def ensure_indexer(%__MODULE__{} = o, definition_name, settings) do
    with {:ok, existing} <- get(o, "/api/v1/indexer", []) do
      case find_definition(existing, definition_name) do
        %{"id" => id} -> {:ok, id}
        nil -> create_indexer(o, definition_name, settings)
      end
    end
  end

  @spec search(t(), integer(), map()) :: {:ok, [Release.t()]} | {:error, term()}
  def search(%__MODULE__{} = o, indexer_id, query) do
    with {:ok, body} <- get(o, "/api/v1/search", search_params(indexer_id, query)) do
      if is_list(body),
        do: {:ok, Enum.map(body, &Release.from_prowlarr/1)},
        else: {:error, {:unexpected_body, body}}
    end
  end

  # -- indexer -----------------------------------------------------------------

  defp create_indexer(o, definition_name, settings) do
    with {:ok, schema} <- get(o, "/api/v1/indexer/schema", []),
         {:ok, entry} <- fetch_definition(schema, definition_name),
         {:ok, created} <- post(o, "/api/v1/indexer", build_indexer(entry, settings)) do
      case created do
        %{"id" => id} -> {:ok, id}
        other -> {:error, {:unexpected_body, other}}
      end
    end
  end

  defp fetch_definition(list, name) do
    case find_definition(list, name) do
      nil -> {:error, :definition_not_found}
      entry -> {:ok, entry}
    end
  end

  defp find_definition(list, name) when is_list(list),
    do: Enum.find(list, &(is_map(&1) and &1["definitionName"] == name))

  defp find_definition(_, _), do: nil

  defp build_indexer(entry, settings) do
    settings = Map.new(settings, fn {k, v} -> {to_string(k), v} end)

    fields =
      Enum.map(entry["fields"] || [], fn field ->
        case Map.fetch(settings, field["name"]) do
          {:ok, value} -> Map.put(field, "value", value)
          :error -> field
        end
      end)

    entry
    |> Map.put("fields", fields)
    |> Map.put("enable", true)
    |> Map.put("appProfileId", 1)
  end

  # -- search ------------------------------------------------------------------

  # SearchResource binds query/type/indexerIds/categories/limit/offset. Ids,
  # season and episode travel inside the query as `{ImdbId:..}` tokens, which
  # NewznabRequest.QueryToParams unpacks for the tvsearch and movie types.
  defp search_params(indexer_id, q) do
    categories = Enum.map(q[:categories] || [], &{:categories, &1})
    paging = for key <- [:limit, :offset], value = q[key], value != nil, do: {key, value}

    [query: query_text(q), type: type_param(q.kind), indexerIds: indexer_id] ++
      categories ++ paging
  end

  defp type_param(:search), do: "search"
  defp type_param(:movie), do: "movie"
  defp type_param(:tv), do: "tvsearch"

  defp query_text(%{kind: :search} = q), do: q.term || ""

  defp query_text(%{kind: kind} = q) do
    tokens =
      [imdbid: q[:imdb_id], tmdbid: q[:tmdb_id]] ++
        if(kind == :tv,
          do: [tvdbid: q[:tvdb_id], season: q[:season], episode: q[:episode]],
          else: []
        )

    token_text = for {name, v} <- tokens, v != nil, v != "", do: "{#{name}:#{v}}"
    Enum.join([q.term || "" | token_text])
  end

  # -- http --------------------------------------------------------------------

  defp get(o, path, params), do: request(o, :get, path, params: params)
  defp post(o, path, json), do: request(o, :post, path, json: json)

  defp request(o, method, path, opts) do
    req_opts =
      [method: method, url: o.base_url <> path, headers: [{"x-api-key", o.api_key}]] ++
        opts ++ o.req_options

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
