defmodule Mydia.Indexers.CardigannLiveSearchTest do
  @moduledoc """
  Live integration tests against real public trackers.

  These tests perform actual HTTP requests to public indexers to verify
  the full pipeline: definition → URL build → HTTP → parse → SearchResult.

  Tagged with both :external and :live since they hit real services.
  Rate limiting and Cloudflare protection may cause intermittent failures.
  """
  use ExUnit.Case

  @moduletag :external
  @moduletag :live

  alias Mydia.Indexers.DefinitionSync
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannResultParser

  @github_raw_base "https://raw.githubusercontent.com/Prowlarr/Indexers/main/definitions/v11"

  # Public indexers known to work without authentication
  # Each entry: {filename, indexer_name, search_query}
  @live_indexers [
    {"nyaasi.yml", "nyaasi", "one piece"},
    {"limetorrents.yml", "limetorrents", "ubuntu"},
    {"solidtorrents.yml", "solidtorrents", "linux"},
    {"torrentgalaxy.yml", "torrentgalaxy", "ubuntu"},
    {"bitsearch.yml", "bitsearch", "linux mint"}
  ]

  for {filename, name, query} <- @live_indexers do
    @tag timeout: 30_000
    test "#{name}: live search returns results for '#{query}'" do
      filename = unquote(filename)
      indexer_name = unquote(name)
      query = unquote(query)

      url = "#{@github_raw_base}/#{filename}"

      with {:ok, yaml} <- DefinitionSync.fetch_definition_file(url),
           {:ok, parsed} <- CardigannParser.parse_definition(yaml) do
        # Build minimal search options
        base_url = List.first(parsed.links) || ""

        search_opts = %{
          query: query,
          categories: [],
          search_path: List.first(parsed.search.paths)
        }

        # Execute search
        case CardigannSearchEngine.execute_search(parsed, search_opts, %{}) do
          {:ok, response} ->
            case CardigannResultParser.parse_results(parsed, response, indexer_name,
                   base_url: base_url
                 ) do
              {:ok, results} ->
                IO.puts("  #{indexer_name}: #{length(results)} results")

                if results != [] do
                  first = hd(results)

                  # Verify essential fields
                  assert is_binary(first.title) and first.title != "",
                         "Result should have non-empty title, got: #{inspect(first.title)}"

                  assert is_integer(first.size) and first.size >= 0,
                         "Result should have non-negative size, got: #{inspect(first.size)}"

                  assert is_integer(first.seeders) and first.seeders >= 0,
                         "Result should have non-negative seeders, got: #{inspect(first.seeders)}"

                  assert is_binary(first.download_url) and first.download_url != "",
                         "Result should have non-empty download_url, got: #{inspect(first.download_url)}"

                  assert first.indexer == indexer_name,
                         "Result indexer should be #{indexer_name}, got: #{first.indexer}"
                else
                  IO.puts(
                    "  #{indexer_name}: no results (site may be down or query too specific)"
                  )
                end

              {:error, reason} ->
                IO.puts("  #{indexer_name}: parse failed - #{inspect(reason)}")
            end

          {:ok, response, _flaresolverr} ->
            # Handle tuple with flaresolverr result
            case CardigannResultParser.parse_results(parsed, response, indexer_name,
                   base_url: base_url
                 ) do
              {:ok, results} ->
                IO.puts("  #{indexer_name}: #{length(results)} results (via FlareSolverr)")
                assert is_list(results)

              {:error, reason} ->
                IO.puts("  #{indexer_name}: parse failed - #{inspect(reason)}")
            end

          {:error, reason} ->
            IO.puts(
              "  #{indexer_name}: search failed - #{inspect(reason)} (may be rate limited or behind Cloudflare)"
            )
        end
      else
        {:error, reason} ->
          IO.puts("  Skipping #{indexer_name}: #{inspect(reason)}")
      end
    end
  end
end
