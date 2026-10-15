defmodule Mydia.Indexers.Cardigann.SearchPages do
  @moduledoc """
  The pages after the first of a multi-path Cardigann search.

  Definitions paginate by listing one `search.paths` entry per page, and
  Prowlarr requests every one that matches. `Adapter.Cardigann.search/3` runs
  page 1 with mirror failover inside the login session, and its error is the
  search's error. The pages here are best effort: each is pinned to the mirror
  page 1 answered on and reuses page 1's session and FlareSolverr clearance. A
  failed page is logged and ends paging, and so does an empty one, because the
  site has run out of results.
  """

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.SearchResult

  require Logger

  @type parse_fun ::
          (map(), CardigannSearchEngine.http_response() ->
             {:ok, [SearchResult.t()]} | {:error, term()})

  @spec collect(Parsed.t(), [map()], keyword(), map(), map(), String.t() | nil, parse_fun()) ::
          [SearchResult.t()]
  def collect(
        %Parsed{} = parsed,
        paths,
        search_opts,
        user_config,
        flaresolverr_opts,
        base_url,
        parse
      ) do
    page_opts =
      search_opts
      |> Keyword.delete(:on_promote)
      |> Keyword.merge(base_url: base_url, pin_base_url: true)

    paths
    |> Enum.with_index(2)
    |> Enum.reduce_while([], fn {path, number}, pages ->
      case fetch_page(parsed, path, page_opts, user_config, flaresolverr_opts, parse) do
        {:ok, []} ->
          {:halt, pages}

        {:ok, rows} ->
          {:cont, [rows | pages]}

        {:error, reason} ->
          Logger.warning(
            "Cardigann #{parsed.name}: search page #{number} failed, keeping the earlier pages: " <>
              inspect(reason)
          )

          {:halt, pages}
      end
    end)
    |> Enum.reverse()
    |> Enum.concat()
  end

  defp fetch_page(parsed, path, page_opts, user_config, flaresolverr_opts, parse) do
    opts = Keyword.put(page_opts, :search_path, path)

    case CardigannSearchEngine.execute_search(parsed, opts, user_config, flaresolverr_opts) do
      {:ok, response} -> parse.(path, response)
      {:ok, response, _markers} -> parse.(path, response)
      {:error, _} = error -> error
    end
  end

  @doc """
  Drops a release a later page repeated, keeping its first occurrence.

  Pages overlap when the site's listing shifts between requests. A release is
  the same when its magnet carries the same info hash, otherwise when its
  download URL is the same.
  """
  @spec dedupe([SearchResult.t()]) :: [SearchResult.t()]
  def dedupe(results), do: Enum.uniq_by(results, &identity/1)

  defp identity(%SearchResult{download_url: url}) do
    case Regex.run(~r/urn:btih:([a-z0-9]+)/i, url || "") do
      [_, hash] -> {:hash, String.downcase(hash)}
      nil -> {:url, url}
    end
  end
end
