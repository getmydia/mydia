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
  alias Mydia.Indexers.RateLimiter
  alias Mydia.Indexers.ReleaseRanker
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannAuth
  alias Mydia.Indexers.CardigannDownload
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Settings
  alias Mydia.Repo
  import Ecto.Query

  @doc """
  Registers all known indexer adapters with the registry.

  This function is called automatically during application startup.
  Adapters must be registered before they can be used.

  ## Registered Adapters

  Currently supported adapters:
    - `:prowlarr` - Prowlarr indexer aggregator
    - `:jackett` - Jackett indexer proxy
    - `:nzbhydra2` - NZBHydra2 Usenet NZB aggregator
    - `:cardigann` - Native Cardigann definition support
  """
  @spec register_adapters() :: :ok
  def register_adapters do
    Logger.info("Registering indexer adapters...")

    # Register adapters
    Adapter.Registry.register(:prowlarr, Mydia.Indexers.Adapter.Prowlarr)
    Adapter.Registry.register(:jackett, Mydia.Indexers.Adapter.Jackett)
    Adapter.Registry.register(:nzbhydra2, Mydia.Indexers.Adapter.NzbHydra2)
    Adapter.Registry.register(:cardigann, Mydia.Indexers.Adapter.Cardigann)

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
  @spec search(Settings.IndexerConfig.t() | map(), binary(), keyword()) ::
          {:ok, [SearchResult.t()]} | {:error, Adapter.Error.t()}
  def search(config, query, opts \\ [])

  def search(%Settings.IndexerConfig{} = config, query, opts) do
    # Check rate limit before making the request
    case RateLimiter.check_rate_limit(config.id, config.rate_limit) do
      :ok ->
        adapter_config = indexer_config_to_adapter_config(config)

        result = search(adapter_config, query, opts)

        # Record the request if successful (even if search returned no results)
        case result do
          {:ok, _results} -> RateLimiter.record_request(config.id)
          {:error, _} -> :ok
        end

        result

      {:error, :rate_limited, retry_after} ->
        Logger.warning(
          "Rate limit exceeded for indexer #{config.name}, retry after #{retry_after}ms"
        )

        {:error, Adapter.Error.rate_limited("Rate limit exceeded, retry after #{retry_after}ms")}
    end
  end

  def search(%{type: type, id: id, rate_limit: rate_limit} = config, query, opts)
      when is_atom(type) and is_binary(id) do
    # Cardigann configs with id and rate_limit go through the rate limiter
    case RateLimiter.check_rate_limit(id, rate_limit) do
      :ok ->
        with {:ok, adapter} <- Adapter.Registry.get_adapter(type) do
          result = adapter.search(config, query, opts)

          case result do
            {:ok, _results} -> RateLimiter.record_request(id)
            {:error, _} -> :ok
          end

          result
        end

      {:error, :rate_limited, retry_after} ->
        Logger.warning(
          "Rate limit exceeded for Cardigann indexer #{config[:name]}, retry after #{retry_after}ms"
        )

        {:error, Adapter.Error.rate_limited("Rate limit exceeded, retry after #{retry_after}ms")}
    end
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
      - `:categories` - List of Torznab category IDs to filter by (default: [])
        Use `Mydia.Indexers.CategoryMapping.categories_for_type/1` to get categories
        for a library type (e.g., `:movies`, `:series`, `:music`, `:books`, `:adult`)
      - `:indexer_ids` - List of indexer config IDs to search (default: all enabled)
        When provided, only the specified indexers will be searched.
      - `:max_concurrency` - Maximum indexers searched at once (default: every
        selected indexer, capped at 16). Falls back to the `:indexer_search`
        application config, then the default.
      - `:deadline_ms` - Milliseconds before a single indexer's search is
        killed and reported as timed out (default: 120_000). Falls back to
        the `:indexer_search` application config, then the default.

  ## Examples

      iex> Mydia.Indexers.search_all("Ubuntu 22.04")
      {:ok, [%SearchResult{indexer: "Prowlarr", ...}, ...]}

      iex> Mydia.Indexers.search_all("Ubuntu", min_seeders: 10, max_results: 50)
      {:ok, [%SearchResult{}, ...]}

      iex> alias Mydia.Indexers.CategoryMapping
      iex> categories = CategoryMapping.categories_for_type(:music)
      iex> Mydia.Indexers.search_all("Beatles", categories: categories)
      {:ok, [%SearchResult{}, ...]}

      iex> Mydia.Indexers.search_all("Ubuntu", indexer_ids: ["abc-123", "def-456"])
      {:ok, [%SearchResult{}, ...]}
  """
  @spec search_all(binary(), keyword()) ::
          {:ok, %{results: [SearchResult.t()], indexer_errors: [map()]}}
  def search_all(query, opts \\ []) do
    indexer_ids = Keyword.get(opts, :indexer_ids)
    on_start = Keyword.get(opts, :on_start, fn _pending -> :ok end)
    on_indexer_result = Keyword.get(opts, :on_indexer_result, fn _progress -> :ok end)

    # Get traditional indexers (Prowlarr, Jackett)
    indexers = Settings.list_indexer_configs()
    enabled_indexers = Enum.filter(indexers, & &1.enabled)

    # Get enabled Cardigann definitions if feature is enabled
    cardigann_configs = get_enabled_cardigann_configs()

    # Filter by specific indexer IDs if provided
    {enabled_indexers, cardigann_configs} =
      if indexer_ids do
        indexer_id_set = MapSet.new(indexer_ids)

        filtered_indexers =
          Enum.filter(enabled_indexers, fn indexer ->
            MapSet.member?(indexer_id_set, indexer.id)
          end)

        filtered_cardigann =
          Enum.filter(cardigann_configs, fn config ->
            MapSet.member?(indexer_id_set, config.id)
          end)

        {filtered_indexers, filtered_cardigann}
      else
        {enabled_indexers, cardigann_configs}
      end

    all_indexers = enabled_indexers ++ cardigann_configs

    if all_indexers == [] do
      Logger.info("No enabled indexers found for query: #{query}")
      {:ok, %{results: [], indexer_errors: []}}
    else
      start_time = System.monotonic_time(:millisecond)
      total = length(all_indexers)

      on_start.(
        Enum.map(all_indexers, fn config ->
          %IndexerProgress{
            indexer: indexer_display_name(config),
            indexer_id: Map.get(config, :id),
            status: :pending,
            total: total
          }
        end)
      )

      {all_results, indexer_errors, _completed} =
        all_indexers
        |> Task.async_stream(
          fn config -> search_with_metrics(config, query, opts) end,
          timeout: search_deadline_ms(opts),
          max_concurrency: get_search_concurrency(total, opts),
          on_timeout: :kill_task,
          zip_input_on_exit: true
        )
        |> Enum.reduce({[], [], 0}, fn
          {:ok, {metrics, results}}, {acc_results, acc_errors, completed} ->
            completed = completed + 1

            on_indexer_result.(%IndexerProgress{
              indexer: metrics.indexer,
              indexer_id: metrics.indexer_id,
              status: if(metrics.success, do: :ok, else: :error),
              results: results,
              result_count: length(results),
              error: metrics.error,
              duration_ms: metrics.duration_ms,
              completed: completed,
              total: total
            })

            if metrics.success do
              {results ++ acc_results, acc_errors, completed}
            else
              error = %{indexer: metrics.indexer, error: metrics.error}
              {acc_results, [error | acc_errors], completed}
            end

          # zip_input_on_exit: true puts the input config in the exit tuple.
          # Without it Task.async_stream never says which element died, which is
          # why this branch used to report "unknown".
          {:exit, {config, reason}}, {acc_results, acc_errors, completed} ->
            completed = completed + 1
            name = indexer_display_name(config)
            message = format_exit_reason(reason)

            Logger.error("Indexer search failed for #{name}: #{inspect(reason)}")

            on_indexer_result.(%IndexerProgress{
              indexer: name,
              indexer_id: Map.get(config, :id),
              status: if(reason == :timeout, do: :timeout, else: :error),
              result_count: 0,
              error: message,
              completed: completed,
              total: total
            })

            {acc_results, [%{indexer: name, error: message} | acc_errors], completed}
        end)

      results = rank_and_dedupe(all_results, query, opts)

      total_time = System.monotonic_time(:millisecond) - start_time

      Logger.info(
        "Search completed: query=#{query}, indexers=#{total}, " <>
          "cardigann=#{length(cardigann_configs)}, results=#{length(results)}, " <>
          "errors=#{length(indexer_errors)}, time=#{total_time}ms"
      )

      {:ok, %{results: results, indexer_errors: Enum.reverse(indexer_errors)}}
    end
  end

  @doc """
  Filters, deduplicates and ranks a raw result set.

  Extracted from `search_all/2` so the manual-search LiveViews can re-rank an
  accumulating result set as each indexer reports, without reimplementing
  ranking in the web layer.

  ## Options

    - `:min_seeders` - drop torrents below this seeder count (default: 0).
      NZB results have nil seeders and are always kept.
    - `:max_results` - truncate to this many results (default: 100)
    - `:deduplicate` - merge duplicate releases (default: true)
  """
  @spec rank_and_dedupe([SearchResult.t()], binary(), keyword()) :: [SearchResult.t()]
  def rank_and_dedupe(results, query, opts \\ []) do
    min_seeders = Keyword.get(opts, :min_seeders, 0)
    max_results = Keyword.get(opts, :max_results, 100)
    should_deduplicate = Keyword.get(opts, :deduplicate, true)

    results
    |> filter_by_seeders(min_seeders)
    |> then(fn results ->
      if should_deduplicate, do: deduplicate_results(results), else: results
    end)
    |> rank_results(query, min_seeders)
    |> Enum.take(max_results)
  end

  @doc """
  Search options for unattended background jobs.

  Background searches run repeatedly across a whole library, so they stay
  throttled to avoid indexer bans. Manual searches deliberately do not use
  this: they fan out fully because a user is waiting.
  """
  @spec background_search_opts() :: keyword()
  def background_search_opts do
    concurrency =
      Application.get_env(:mydia, :indexer_search, [])[:background_max_concurrency] || 2

    [max_concurrency: concurrency]
  end

  @doc """
  Tests the connection to an indexer.

  ## Examples

      iex> config = %{type: :prowlarr, base_url: "http://localhost:9696", api_key: "..."}
      iex> Mydia.Indexers.test_connection(config)
      {:ok, %{name: "Prowlarr", version: "1.0.0"}}
  """
  @spec test_connection(Settings.IndexerConfig.t() | map()) ::
          {:ok, map()} | {:error, Adapter.Error.t()}
  def test_connection(%Settings.IndexerConfig{} = config) do
    adapter_config = indexer_config_to_adapter_config(config)
    test_connection(adapter_config)
  end

  def test_connection(%{type: type} = config) when is_atom(type) do
    adapter_config = maybe_convert_base_url(config)

    with {:ok, adapter} <- Adapter.Registry.get_adapter(type) do
      adapter.test_connection(adapter_config)
    end
  end

  @doc """
  Gets the capabilities of an indexer.

  ## Examples

      iex> config = %{type: :prowlarr, base_url: "http://localhost:9696", api_key: "..."}
      iex> Mydia.Indexers.get_capabilities(config)
      {:ok, %{searching: %{...}, categories: [...]}}
  """
  @spec get_capabilities(Settings.IndexerConfig.t() | map()) ::
          {:ok, map()} | {:error, Adapter.Error.t()}
  def get_capabilities(%Settings.IndexerConfig{} = config) do
    adapter_config = indexer_config_to_adapter_config(config)
    get_capabilities(adapter_config)
  end

  def get_capabilities(%{type: type} = config) when is_atom(type) do
    with {:ok, adapter} <- Adapter.Registry.get_adapter(type) do
      adapter.get_capabilities(config)
    end
  end

  @doc """
  Lists all indexers available in a Prowlarr instance.

  This is used to populate the indexer selection UI when configuring
  which Prowlarr indexers to enable for searches.

  ## Parameters
    - `config` - Either an IndexerConfig struct or a map with connection details
                 (base_url, api_key required)

  ## Returns
    - `{:ok, indexers}` - List of %{id, name, enabled, protocol} maps
    - `{:error, reason}` - If the config is not Prowlarr or connection fails

  ## Examples

      iex> config = Settings.get_indexer_config!(id)
      iex> Mydia.Indexers.list_prowlarr_indexers(config)
      {:ok, [%{id: 1, name: "TorrentLeech", enabled: true, protocol: "torrent"}, ...]}
  """
  @spec list_prowlarr_indexers(Settings.IndexerConfig.t() | map()) ::
          {:ok, [map()]} | {:error, binary()}
  def list_prowlarr_indexers(%Settings.IndexerConfig{type: :prowlarr} = config) do
    adapter_config = indexer_config_to_adapter_config(config)
    Adapter.Prowlarr.list_indexers(adapter_config)
  end

  def list_prowlarr_indexers(%Settings.IndexerConfig{type: type}) do
    {:error, "Cannot list indexers for type #{type} - only supported for Prowlarr"}
  end

  def list_prowlarr_indexers(%{base_url: base_url, api_key: api_key})
      when is_binary(base_url) and is_binary(api_key) do
    # Build a minimal adapter config from raw connection details
    uri = URI.parse(base_url)

    adapter_config = %{
      type: :prowlarr,
      host: uri.host || "localhost",
      port: uri.port || default_port(uri.scheme),
      api_key: api_key,
      use_ssl: uri.scheme == "https",
      options: %{
        base_path: uri.path
      }
    }

    Adapter.Prowlarr.list_indexers(adapter_config)
  end

  def list_prowlarr_indexers(_config) do
    {:error, "Invalid config - requires base_url and api_key"}
  end

  ## Private Functions

  # Fetches enabled Cardigann definitions and converts them to adapter config format
  defp get_enabled_cardigann_configs do
    alias Mydia.Indexers.CardigannFeatureFlags

    if CardigannFeatureFlags.enabled?() do
      list_cardigann_definitions(enabled: true)
      |> Enum.map(&cardigann_definition_to_config/1)
    else
      []
    end
  end

  # Converts a CardigannDefinition to the config map expected by the Cardigann adapter
  defp cardigann_definition_to_config(%CardigannDefinition{} = definition) do
    %{
      id: definition.id,
      type: :cardigann,
      name: definition.name,
      indexer_id: definition.indexer_id,
      enabled: definition.enabled,
      user_settings: definition.config || %{},
      rate_limit: get_default_cardigann_rate_limit()
    }
  end

  defp get_default_cardigann_rate_limit do
    Application.get_env(:mydia, :indexer_search, [])
    |> Keyword.get(:default_cardigann_rate_limit, 3)
  end

  # Defaults to searching every selected indexer at once, capped at 16. The
  # previous default of 2 meant six indexers at a normal 30s response took 90
  # seconds even when all were healthy, and a single wedged indexer held one of
  # only two slots for its whole duration. An explicit config value still wins,
  # so a deployment that deliberately throttled stays throttled.
  defp get_search_concurrency(indexer_count, opts) do
    Keyword.get(opts, :max_concurrency) ||
      Application.get_env(:mydia, :indexer_search, [])[:max_concurrency] ||
      min(max(indexer_count, 1), 16)
  end

  # 4x a normal 30s response. Generous on purpose: indexers here are legitimately
  # slow and do eventually answer, so this is a backstop against a wedged
  # connection rather than a latency budget.
  defp search_deadline_ms(opts) do
    Keyword.get(opts, :deadline_ms) ||
      Application.get_env(:mydia, :indexer_search, [])[:deadline_ms] ||
      120_000
  end

  defp indexer_display_name(%{name: name}) when is_binary(name), do: name
  defp indexer_display_name(_config), do: "unknown"

  defp format_exit_reason(:timeout), do: "Timed out"
  defp format_exit_reason(reason), do: "Task crashed: #{inspect(reason)}"

  defp search_with_metrics(config, query, opts) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case search(config, query, opts) do
        {:ok, results} ->
          # Per-indexer-config NZB min-post-age filter (#121). Applied here
          # rather than post-merge because `SearchResult.indexer` is the
          # *upstream* label for relay-style indexers (Prowlarr, Jackett) —
          # one Mydia config like "Prowlarr" can fan out to many upstream
          # indexers ("DOGnzb", "altHUB", etc.) so a post-merge lookup
          # keyed by `result.indexer` would never match the configured
          # name. Doing it here, with the originating config in scope,
          # sidesteps that gap entirely.
          filtered = reject_too_fresh_nzbs_for_config(results, config)
          {true, filtered, nil}

        {:error, error} ->
          Logger.warning("Indexer search failed for #{config.name}: #{inspect(error)}")

          {false, [], format_indexer_error(error)}
      end

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    {success, results, error_message} = result

    metrics = %{
      indexer: config.name,
      indexer_id: Map.get(config, :id),
      success: success,
      duration_ms: duration,
      result_count: length(results),
      error: error_message
    }

    Logger.debug(
      "Indexer search: name=#{config.name}, success=#{success}, " <>
        "results=#{length(results)}, duration=#{duration}ms"
    )

    {metrics, results}
  end

  # Drops NZB results younger than `config.min_post_age_minutes`. No-op when
  # the config has no setting (nil/0) or the value isn't a positive integer,
  # so Cardigann definitions and indexer configs that left the field blank
  # both pass through unchanged. Torrent results and NZB results without a
  # parsed `usenet_date` are always kept — the filter is opt-in per indexer.
  defp reject_too_fresh_nzbs_for_config(results, config) do
    case Map.get(config, :min_post_age_minutes) do
      minutes when is_integer(minutes) and minutes > 0 ->
        now = DateTime.utc_now()
        cutoff_seconds = minutes * 60

        Enum.reject(results, fn r ->
          case {Map.get(r, :download_protocol), Map.get(r, :usenet_date)} do
            {:nzb, %DateTime{} = posted} ->
              if DateTime.diff(now, posted, :second) < cutoff_seconds do
                Logger.debug(
                  "Filtered too-fresh NZB",
                  indexer_config: config.name,
                  title: Map.get(r, :title),
                  usenet_date: posted
                )

                true
              else
                false
              end

            _ ->
              false
          end
        end)

      _ ->
        results
    end
  end

  defp format_indexer_error(%{message: message}) when is_binary(message), do: message
  defp format_indexer_error(error) when is_binary(error), do: error
  defp format_indexer_error(error), do: inspect(error)

  defp filter_by_seeders(results, min_seeders) when min_seeders > 0 do
    # NZB results have nil seeders; the min-seeders setting is torrent-only.
    Enum.filter(results, fn result -> is_nil(result.seeders) or result.seeders >= min_seeders end)
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
      # NZB results have nil seeders; treat as 0 for ordering only.
      {result.seeders || 0, has_complete_metadata?(result)}
    end)
  end

  defp has_complete_metadata?(%SearchResult{quality: quality}) do
    quality != nil && quality.resolution != nil && quality.source != nil
  end

  defp rank_results(results, search_query, min_seeders) do
    # Use the unified ReleaseRanker for consistent scoring across manual and automated searches
    # This provides sophisticated ranking with size scoring, age scoring, seeder ratio multipliers,
    # and title relevance scoring
    ranked_results =
      ReleaseRanker.rank_all(results, min_seeders: min_seeders, search_query: search_query)

    # Extract the SearchResult from each RankedResult to maintain the expected return type
    Enum.map(ranked_results, fn ranked -> ranked.result end)
  end

  defp indexer_config_to_adapter_config(%Settings.IndexerConfig{} = config) do
    # Resolve environment variable inheritance if env_name is set
    resolved_config = Settings.resolve_env_inheritance(config)

    # Parse base_url to extract host, port, and use_ssl
    uri = URI.parse(resolved_config.base_url)

    # Get timeout from connection_settings or use default
    timeout =
      case resolved_config.connection_settings do
        %{"timeout" => timeout} when is_integer(timeout) -> timeout
        _ -> 30_000
      end

    %{
      type: resolved_config.type,
      name: resolved_config.name,
      host: uri.host || "localhost",
      port: uri.port || default_port(uri.scheme),
      api_key: resolved_config.api_key,
      use_ssl: uri.scheme == "https",
      options: %{
        indexer_ids: resolved_config.indexer_ids || [],
        categories: resolved_config.categories || [],
        rate_limit: resolved_config.rate_limit,
        timeout: timeout,
        base_path: uri.path
      }
    }
  end

  # Converts a plain config map with base_url into the adapter format with host/port/use_ssl.
  # This handles the case where test_connection is called from the UI with a raw config map
  # rather than an IndexerConfig struct.
  defp maybe_convert_base_url(%{base_url: base_url} = config) when is_binary(base_url) do
    uri = URI.parse(base_url)

    config
    |> Map.put(:host, uri.host || "localhost")
    |> Map.put(:port, uri.port || default_port(uri.scheme))
    |> Map.put(:use_ssl, uri.scheme == "https")
    |> Map.put(:name, Map.get(config, :name, "Test"))
    |> Map.put_new(:options, %{
      indexer_ids: [],
      categories: [],
      base_path: uri.path
    })
  end

  defp maybe_convert_base_url(config), do: config

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: 80

  ## Cardigann Definition Management

  @doc """
  Lists all Cardigann definitions with optional filtering.

  ## Options
    - `:type` - Filter by indexer type ("public", "private", "semi-private")
    - `:language` - Filter by language code (e.g., "en-US")
    - `:enabled` - Filter by enabled status (true/false)
    - `:search` - Search by name or description (case-insensitive)

  ## Examples

      iex> Mydia.Indexers.list_cardigann_definitions()
      [%CardigannDefinition{}, ...]

      iex> Mydia.Indexers.list_cardigann_definitions(type: "public", enabled: true)
      [%CardigannDefinition{}, ...]
  """
  @spec list_cardigann_definitions(keyword()) :: [CardigannDefinition.t()]
  def list_cardigann_definitions(opts \\ []) do
    query = from(d in CardigannDefinition, order_by: [asc: d.name])

    query
    |> apply_cardigann_filters(opts)
    |> Repo.all()
  end

  @doc """
  Gets a single Cardigann definition by ID.

  Raises `Ecto.NoResultsError` if the definition does not exist.
  """
  @spec get_cardigann_definition!(binary()) :: CardigannDefinition.t()
  def get_cardigann_definition!(id) do
    Repo.get!(CardigannDefinition, id)
  end

  @doc """
  Gets a single Cardigann definition by indexer_id.

  Returns nil if the definition does not exist.
  """
  @spec get_cardigann_definition_by_indexer_id(binary()) :: CardigannDefinition.t() | nil
  def get_cardigann_definition_by_indexer_id(indexer_id) do
    Repo.get_by(CardigannDefinition, indexer_id: indexer_id)
  end

  @doc """
  Gets a single Cardigann definition by name.

  Returns nil if the definition does not exist.
  """
  @spec get_cardigann_definition_by_name(binary()) :: CardigannDefinition.t() | nil
  def get_cardigann_definition_by_name(name) do
    Repo.get_by(CardigannDefinition, name: name)
  end

  @doc """
  Gets authentication cookies for a Cardigann indexer by name.

  Returns a list of cookie strings if the indexer has an active session,
  or an empty list if no session exists or authentication is not required.
  """
  @spec get_cardigann_auth_cookies(binary()) :: [binary()]
  def get_cardigann_auth_cookies(indexer_name) do
    case get_cardigann_definition_by_name(indexer_name) do
      nil ->
        []

      definition ->
        case CardigannAuth.get_stored_session(definition.id) do
          {:ok, session} -> session.cookies || []
          {:error, _} -> []
        end
    end
  end

  @doc """
  Gets download configuration for a Cardigann indexer by name.

  Returns a map with:
  - `:cookies` - List of authentication cookies
  - `:flaresolverr_enabled` - Whether FlareSolverr is required for this indexer

  Returns nil if indexer not found.
  """
  @spec get_cardigann_download_config(binary()) ::
          %{cookies: [binary()], flaresolverr_enabled: boolean()} | nil
  def get_cardigann_download_config(indexer_name) do
    case get_cardigann_definition_by_name(indexer_name) do
      nil ->
        nil

      definition ->
        cookies =
          case CardigannAuth.get_stored_session(definition.id) do
            {:ok, session} -> session.cookies || []
            {:error, _} -> []
          end

        %{
          cookies: cookies,
          flaresolverr_enabled: definition.flaresolverr_enabled || false
        }
    end
  end

  @doc """
  Resolves a download URL through a Cardigann indexer's `download:` block.

  Definitions for sites that do not serve a `.torrent` at the row's link
  describe how to derive the real download instead - a metadata request, an
  infohash to build a magnet from, or a selector pointing at the true link.
  Grabbing such an indexer without this step fetches a landing page and fails.

  Returns `:not_applicable` when the indexer is unknown, is not a Cardigann
  definition, or has no `download:` block to act on, in which case the caller
  should fetch the URL directly as before.

  ## Examples

      iex> resolve_cardigann_download("MagnetDownload", "https://site/info/123")
      {:ok, {:magnet, "magnet:?xt=urn:btih:..."}}

      iex> resolve_cardigann_download("SomeTorrentSite", "https://site/dl/123")
      :not_applicable
  """
  @spec resolve_cardigann_download(binary() | nil, binary()) ::
          {:ok, {:magnet, binary()} | {:link, binary()}} | {:error, term()} | :not_applicable
  def resolve_cardigann_download(nil, _download_url), do: :not_applicable

  def resolve_cardigann_download(indexer_name, download_url) when is_binary(indexer_name) do
    with %CardigannDefinition{} = definition <- get_cardigann_definition_by_name(indexer_name),
         {:ok, parsed} <- CardigannParser.parse_definition(definition.definition) do
      CardigannDownload.resolve(parsed, download_url, %{
        cookies: get_cardigann_auth_cookies(indexer_name),
        base_url: definition.active_link
      })
    else
      nil ->
        :not_applicable

      {:error, reason} ->
        Logger.warning(
          "Could not parse Cardigann definition for #{indexer_name}: #{inspect(reason)}"
        )

        :not_applicable
    end
  end

  def resolve_cardigann_download(_indexer_name, _download_url), do: :not_applicable

  @doc """
  Enables a Cardigann indexer definition.

  ## Examples

      iex> enable_cardigann_definition(definition)
      {:ok, %CardigannDefinition{enabled: true}}
  """
  @spec enable_cardigann_definition(CardigannDefinition.t()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def enable_cardigann_definition(%CardigannDefinition{} = definition) do
    definition
    |> CardigannDefinition.toggle_changeset(%{enabled: true})
    |> Repo.update()
  end

  @doc """
  Disables a Cardigann indexer definition.

  ## Examples

      iex> disable_cardigann_definition(definition)
      {:ok, %CardigannDefinition{enabled: false}}
  """
  @spec disable_cardigann_definition(CardigannDefinition.t()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def disable_cardigann_definition(%CardigannDefinition{} = definition) do
    definition
    |> CardigannDefinition.toggle_changeset(%{enabled: false})
    |> Repo.update()
  end

  @doc """
  Updates the configuration for a Cardigann definition (credentials, etc.).

  ## Examples

      iex> configure_cardigann_definition(definition, %{username: "user", password: "pass"})
      {:ok, %CardigannDefinition{config: %{username: "user", ...}}}
  """
  @spec configure_cardigann_definition(CardigannDefinition.t(), map()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def configure_cardigann_definition(%CardigannDefinition{} = definition, config) do
    definition
    |> CardigannDefinition.config_changeset(%{config: config})
    |> Repo.update()
  end

  @doc """
  Tests the connection to a Cardigann indexer definition.

  This validates that the indexer is reachable and properly configured.

  ## Examples

      iex> test_cardigann_definition(definition)
      {:ok, %{success: true, status: "healthy", ...}}
  """
  @spec test_cardigann_definition(CardigannDefinition.t()) :: {:ok, map()} | {:error, term()}
  def test_cardigann_definition(%CardigannDefinition{} = definition) do
    alias Mydia.Indexers.CardigannHealthCheck

    CardigannHealthCheck.execute_health_check(definition)
  end

  @doc """
  Tests connection to a Cardigann indexer by ID.

  Performs a test search to verify connectivity, authentication, and response.
  Updates the health status in the database.

  ## Examples

      iex> test_cardigann_connection("abc-123")
      {:ok, %{success: true, status: "healthy", ...}}
  """
  @spec test_cardigann_connection(binary()) :: {:ok, map()} | {:error, term()}
  def test_cardigann_connection(definition_id) when is_binary(definition_id) do
    alias Mydia.Indexers.CardigannHealthCheck

    CardigannHealthCheck.test_connection(definition_id)
  end

  @doc """
  Counts Cardigann definitions by status.

  Returns a map with counts for enabled, disabled, and total definitions.

  ## Examples

      iex> count_cardigann_definitions()
      %{total: 100, enabled: 25, disabled: 75}
  """
  @spec count_cardigann_definitions() :: %{
          total: non_neg_integer(),
          enabled: non_neg_integer(),
          disabled: non_neg_integer()
        }
  def count_cardigann_definitions do
    total = Repo.aggregate(CardigannDefinition, :count, :id)
    enabled = Repo.aggregate(from(d in CardigannDefinition, where: d.enabled), :count, :id)

    %{
      total: total,
      enabled: enabled,
      disabled: total - enabled
    }
  end

  ## FlareSolverr Functions

  @doc """
  Updates the FlareSolverr settings for a Cardigann definition.

  ## Examples

      iex> update_flaresolverr_settings(definition, %{flaresolverr_enabled: true})
      {:ok, %CardigannDefinition{flaresolverr_enabled: true}}
  """
  @spec update_flaresolverr_settings(CardigannDefinition.t(), map()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def update_flaresolverr_settings(%CardigannDefinition{} = definition, attrs) do
    definition
    |> CardigannDefinition.flaresolverr_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Sets whether a Cardigann definition requires FlareSolverr.

  This is typically set automatically when Cloudflare challenges are detected.

  ## Examples

      iex> set_flaresolverr_required(definition, true)
      {:ok, %CardigannDefinition{flaresolverr_required: true}}
  """
  @spec set_flaresolverr_required(CardigannDefinition.t(), boolean()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def set_flaresolverr_required(%CardigannDefinition{} = definition, required?)
      when is_boolean(required?) do
    update_flaresolverr_settings(definition, %{flaresolverr_required: required?})
  end

  @doc """
  Lists all Cardigann definitions that have FlareSolverr enabled.

  ## Examples

      iex> list_flaresolverr_enabled_definitions()
      [%CardigannDefinition{flaresolverr_enabled: true}, ...]
  """
  @spec list_flaresolverr_enabled_definitions() :: [CardigannDefinition.t()]
  def list_flaresolverr_enabled_definitions do
    from(d in CardigannDefinition,
      where: d.flaresolverr_enabled == true,
      order_by: [asc: d.name]
    )
    |> Repo.all()
  end

  @doc """
  Lists all Cardigann definitions that require FlareSolverr.

  ## Examples

      iex> list_flaresolverr_required_definitions()
      [%CardigannDefinition{flaresolverr_required: true}, ...]
  """
  @spec list_flaresolverr_required_definitions() :: [CardigannDefinition.t()]
  def list_flaresolverr_required_definitions do
    from(d in CardigannDefinition,
      where: d.flaresolverr_required == true,
      order_by: [asc: d.name]
    )
    |> Repo.all()
  end

  ## Private Cardigann Helpers

  defp apply_cardigann_filters(query, []), do: query

  defp apply_cardigann_filters(query, [{:type, type} | rest]) when is_binary(type) do
    query
    |> where([d], d.type == ^type)
    |> apply_cardigann_filters(rest)
  end

  defp apply_cardigann_filters(query, [{:language, language} | rest]) when is_binary(language) do
    query
    |> where([d], d.language == ^language)
    |> apply_cardigann_filters(rest)
  end

  defp apply_cardigann_filters(query, [{:enabled, enabled} | rest]) when is_boolean(enabled) do
    query
    |> where([d], d.enabled == ^enabled)
    |> apply_cardigann_filters(rest)
  end

  defp apply_cardigann_filters(query, [{:search, search_term} | rest])
       when is_binary(search_term) do
    search_pattern = "%#{String.downcase(search_term)}%"

    query
    |> where(
      [d],
      like(fragment("lower(?)", d.name), ^search_pattern) or
        like(fragment("lower(?)", d.description), ^search_pattern)
    )
    |> apply_cardigann_filters(rest)
  end

  defp apply_cardigann_filters(query, [_unknown | rest]) do
    apply_cardigann_filters(query, rest)
  end
end
