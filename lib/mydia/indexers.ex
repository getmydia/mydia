defmodule Mydia.Indexers do
  @moduledoc """
  The Indexers context handles indexer and search provider operations.

  This module provides the main API for searching across configured indexers,
  managing indexer configurations, and registering indexer adapters.

  ## Adapter Registration

  Indexer adapters must be registered before they can be used. Registration
  happens automatically at application startup via `register_adapters/0`.

  ## Searching

  To search across all configured indexers:

      Mydia.Indexers.search_all("Ubuntu 22.04", min_seeders: 5)

  To search a specific indexer:

      config = Mydia.Settings.get_indexer_config!(id)
      Mydia.Indexers.search(config, "Ubuntu 22.04")
  """

  require Logger
  alias Mydia.Indexers.Adapter
  alias Mydia.Indexers.SearchResult
  alias Mydia.Settings

  @doc """
  Registers all known indexer adapters with the registry.

  This function is called automatically during application startup.
  Adapters must be registered before they can be used.

  ## Registered Adapters

  Currently supported adapters:
    - `:prowlarr` - Prowlarr indexer aggregator (when implemented)
    - `:jackett` - Jackett indexer proxy (when implemented)
  """
  def register_adapters do
    Logger.info("Registering indexer adapters...")

    # Register adapters as they are implemented
    Adapter.Registry.register(:prowlarr, Mydia.Indexers.Adapter.Prowlarr)
    # Adapter.Registry.register(:jackett, Mydia.Indexers.Adapter.Jackett)

    Logger.info("Indexer adapter registration complete")
    :ok
  end

  @doc """
  Searches a specific indexer with the given query.

  ## Parameters
    - `config` - Indexer configuration map or IndexerConfig struct
    - `query` - Search query string
    - `opts` - Search options (see `Mydia.Indexers.Adapter` for available options)

  ## Examples

      iex> config = %{type: :prowlarr, base_url: "http://localhost:9696", api_key: "..."}
      iex> Mydia.Indexers.search(config, "Ubuntu")
      {:ok, [%SearchResult{}, ...]}
  """
  def search(config, query, opts \\ [])

  def search(%Settings.IndexerConfig{} = config, query, opts) do
    adapter_config = indexer_config_to_adapter_config(config)
    search(adapter_config, query, opts)
  end

  def search(%{type: type} = config, query, opts) when is_atom(type) do
    with {:ok, adapter} <- Adapter.Registry.get_adapter(type) do
      adapter.search(config, query, opts)
    end
  end

  @doc """
  Searches all enabled indexers configured in the system.

  Results from all indexers are returned in a single list, deduplicated,
  and ranked by quality score and seeders.

  This function executes searches concurrently using Task.async_stream with
  configurable timeouts per indexer. Performance metrics are logged for each
  indexer, and individual failures don't block other results.

  ## Parameters
    - `query` - Search query string
    - `opts` - Search options:
      - `:min_seeders` - Minimum seeder count filter (default: 0)
      - `:max_results` - Maximum number of results to return (default: 100)
      - `:deduplicate` - Whether to deduplicate results (default: true)

  ## Examples

      iex> Mydia.Indexers.search_all("Ubuntu 22.04")
      {:ok, [%SearchResult{indexer: "Prowlarr", ...}, ...]}

      iex> Mydia.Indexers.search_all("Ubuntu", min_seeders: 10, max_results: 50)
      {:ok, [%SearchResult{}, ...]}
  """
  def search_all(query, opts \\ []) do
    min_seeders = Keyword.get(opts, :min_seeders, 0)
    max_results = Keyword.get(opts, :max_results, 100)
    should_deduplicate = Keyword.get(opts, :deduplicate, true)

    indexers = Settings.list_indexer_configs()
    enabled_indexers = Enum.filter(indexers, & &1.enabled)

    if enabled_indexers == [] do
      Logger.info("No enabled indexers found for query: #{query}")
      {:ok, []}
    else
      start_time = System.monotonic_time(:millisecond)

      results =
        enabled_indexers
        |> Task.async_stream(
          fn config -> search_with_metrics(config, query, opts) end,
          timeout: :infinity,
          max_concurrency: System.schedulers_online() * 2,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {_metrics, results}} ->
            results

          {:exit, reason} ->
            Logger.error("Indexer search task crashed: #{inspect(reason)}")
            []
        end)
        |> filter_by_seeders(min_seeders)
        |> then(fn results ->
          if should_deduplicate, do: deduplicate_results(results), else: results
        end)
        |> rank_results()
        |> Enum.take(max_results)

      total_time = System.monotonic_time(:millisecond) - start_time

      Logger.info(
        "Search completed: query=#{query}, indexers=#{length(enabled_indexers)}, " <>
          "results=#{length(results)}, time=#{total_time}ms"
      )

      {:ok, results}
    end
  end

  @doc """
  Tests the connection to an indexer.

  ## Examples

      iex> config = %{type: :prowlarr, base_url: "http://localhost:9696", api_key: "..."}
      iex> Mydia.Indexers.test_connection(config)
      {:ok, %{name: "Prowlarr", version: "1.0.0"}}
  """
  def test_connection(%Settings.IndexerConfig{} = config) do
    adapter_config = indexer_config_to_adapter_config(config)
    test_connection(adapter_config)
  end

  def test_connection(%{type: type} = config) when is_atom(type) do
    with {:ok, adapter} <- Adapter.Registry.get_adapter(type) do
      adapter.test_connection(config)
    end
  end

  @doc """
  Gets the capabilities of an indexer.

  ## Examples

      iex> config = %{type: :prowlarr, base_url: "http://localhost:9696", api_key: "..."}
      iex> Mydia.Indexers.get_capabilities(config)
      {:ok, %{searching: %{...}, categories: [...]}}
  """
  def get_capabilities(%Settings.IndexerConfig{} = config) do
    adapter_config = indexer_config_to_adapter_config(config)
    get_capabilities(adapter_config)
  end

  def get_capabilities(%{type: type} = config) when is_atom(type) do
    with {:ok, adapter} <- Adapter.Registry.get_adapter(type) do
      adapter.get_capabilities(config)
    end
  end

  ## Private Functions

  defp search_with_metrics(config, query, opts) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case search(config, query, opts) do
        {:ok, results} ->
          {true, results}

        {:error, error} ->
          Logger.warning("Indexer search failed for #{config.name}: #{inspect(error)}")

          {false, []}
      end

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    {success, results} = result

    metrics = %{
      indexer: config.name,
      success: success,
      duration_ms: duration,
      result_count: length(results)
    }

    Logger.debug(
      "Indexer search: name=#{config.name}, success=#{success}, " <>
        "results=#{length(results)}, duration=#{duration}ms"
    )

    {metrics, results}
  end

  defp filter_by_seeders(results, min_seeders) when min_seeders > 0 do
    Enum.filter(results, fn result -> result.seeders >= min_seeders end)
  end

  defp filter_by_seeders(results, _min_seeders), do: results

  defp deduplicate_results(results) do
    # Group results by normalized title and hash
    results
    |> Enum.group_by(&dedup_key/1)
    |> Enum.map(fn {_key, group} ->
      # For each group, merge duplicates by taking the best one
      merge_duplicates(group)
    end)
  end

  defp dedup_key(result) do
    # Extract hash from magnet link if available
    hash = extract_hash_from_url(result.download_url)
    normalized_title = normalize_title(result.title)

    {hash, normalized_title}
  end

  defp extract_hash_from_url(url) when is_binary(url) do
    case Regex.run(~r/urn:btih:([a-f0-9]{40})/i, url) do
      [_, hash] -> String.downcase(hash)
      nil -> nil
    end
  end

  defp normalize_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp merge_duplicates([single]), do: single

  defp merge_duplicates(duplicates) do
    # When we have duplicates, prefer:
    # 1. Results with more seeders
    # 2. Results from more reliable sources (if we had source ranking)
    # 3. Results with complete metadata
    Enum.max_by(duplicates, fn result ->
      {result.seeders, has_complete_metadata?(result)}
    end)
  end

  defp has_complete_metadata?(%SearchResult{quality: quality}) do
    quality != nil && quality.resolution != nil && quality.source != nil
  end

  defp rank_results(results) do
    results
    |> Enum.sort_by(&ranking_score/1, :desc)
  end

  defp ranking_score(result) do
    quality_score = calculate_quality_score(result)
    seeder_score = calculate_seeder_score(result.seeders)
    health_score = SearchResult.health_score(result) * 100

    # Weighted scoring:
    # - Quality: 60% (most important for media)
    # - Seeders: 30% (important for download speed)
    # - Health: 10% (good balance indicator)
    quality_score * 0.6 + seeder_score * 0.3 + health_score * 0.1
  end

  defp calculate_quality_score(%SearchResult{quality: nil}), do: 0.0

  defp calculate_quality_score(%SearchResult{quality: quality}) do
    alias Mydia.Indexers.QualityParser

    # Use the QualityParser's scoring, normalized to 0-1000 range
    QualityParser.quality_score(quality) |> min(2000) |> max(0)
  end

  defp calculate_seeder_score(seeders) when seeders <= 0, do: 0.0

  defp calculate_seeder_score(seeders) do
    # Logarithmic scale for seeders (diminishing returns)
    # 1 seeder = ~0, 10 seeders = ~100, 100 seeders = ~200, 1000 seeders = ~300
    :math.log10(seeders) * 100
  end

  defp indexer_config_to_adapter_config(%Settings.IndexerConfig{} = config) do
    # Parse base_url to extract host, port, and use_ssl
    uri = URI.parse(config.base_url)

    # Get timeout from connection_settings or use default
    timeout =
      case config.connection_settings do
        %{"timeout" => timeout} when is_integer(timeout) -> timeout
        _ -> 30_000
      end

    %{
      type: config.type,
      name: config.name,
      host: uri.host || "localhost",
      port: uri.port || default_port(uri.scheme),
      api_key: config.api_key,
      use_ssl: uri.scheme == "https",
      options: %{
        indexer_ids: config.indexer_ids || [],
        categories: config.categories || [],
        rate_limit: config.rate_limit,
        timeout: timeout,
        base_path: uri.path
      }
    }
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: 80
end
