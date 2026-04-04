defmodule Mydia.Search.Pipeline do
  @moduledoc """
  Shared search-and-rank pipeline used by MovieSearch, MovieUpgradeSearch,
  and future search jobs.

  Contains the common primitives for building search queries, loading quality
  profiles, building ranking options, and initiating downloads. Orchestration
  (backoff, events, what to do with results) is left to each job.
  """

  import Ecto.Query, warn: false

  alias Mydia.{Repo, Indexers, Downloads}
  alias Mydia.Media.MediaItem

  # -- Search Query Building --

  @doc """
  Builds a search query string from a media item's title and year.
  """
  @spec build_search_query(MediaItem.t()) :: String.t()
  def build_search_query(%MediaItem{title: title, year: nil}), do: title
  def build_search_query(%MediaItem{title: title, year: year}), do: "#{title} #{year}"

  # -- Indexer Helpers --

  @doc """
  Returns the configured minimum seeders threshold (defaults to 0 for Usenet compatibility).
  """
  @spec get_min_seeders() :: non_neg_integer()
  def get_min_seeders do
    Application.get_env(:mydia, :auto_search, [])[:min_seeders] || 0
  end

  @doc """
  Counts all enabled indexers (standard + Cardigann).
  """
  @spec count_enabled_indexers() :: non_neg_integer()
  def count_enabled_indexers do
    indexers = Mydia.Settings.list_indexer_configs()
    enabled_count = Enum.count(indexers, & &1.enabled)

    cardigann_count =
      if Application.get_env(:mydia, :features, [])[:cardigann_indexers] do
        Indexers.list_cardigann_definitions()
        |> Enum.count(& &1.enabled)
      else
        0
      end

    enabled_count + cardigann_count
  end

  @doc """
  Applies the configured search delay between searches to avoid indexer rate limiting.
  """
  @spec apply_search_delay() :: :ok
  def apply_search_delay do
    delay = get_search_delay_ms()

    if delay > 0 do
      Process.sleep(delay)
    end

    :ok
  end

  defp get_search_delay_ms do
    Application.get_env(:mydia, :episode_monitor, [])
    |> Keyword.get(:search_delay_ms, 0)
  end

  # -- Quality Profile --

  @doc """
  Loads the quality profile for a media item, if one is assigned.
  """
  @spec load_quality_profile(MediaItem.t()) :: Mydia.Settings.QualityProfile.t() | nil
  def load_quality_profile(%MediaItem{quality_profile_id: nil}), do: nil

  def load_quality_profile(%MediaItem{} = media_item) do
    media_item
    |> Repo.preload(:quality_profile)
    |> Map.get(:quality_profile)
  end

  # -- Ranking Options --

  @doc """
  Builds ranking options for `ReleaseRanker.select_best_result/2`.

  Accepts explicit options that override defaults:
    - `:min_seeders` - minimum seeder count
    - `:size_range` - `{min_mb, max_mb}` tuple
    - `:blocked_tags` - list of blocked tag strings
    - `:preferred_tags` - list of preferred tag strings
    - `:media_type` - `:movie` or `:episode`
  """
  @spec build_ranking_options(MediaItem.t(), keyword()) :: keyword()
  def build_ranking_options(%MediaItem{} = media_item, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)

    base_opts = [
      min_seeders: Keyword.get(opts, :min_seeders, get_min_seeders()),
      size_range: Keyword.get(opts, :size_range),
      search_query: build_search_query(media_item),
      media_type: media_type,
      expected_title: media_item.title
    ]

    opts_with_quality =
      case load_quality_profile(media_item) do
        nil ->
          base_opts

        quality_profile ->
          base_opts
          |> Keyword.put(:quality_profile, quality_profile)
          |> Keyword.merge(build_quality_options(quality_profile, media_type))
      end

    opts_with_quality
    |> maybe_add_option(:blocked_tags, Keyword.get(opts, :blocked_tags))
    |> maybe_add_option(:preferred_tags, Keyword.get(opts, :preferred_tags))
  end

  @doc """
  Extracts quality filtering options from a quality profile.
  """
  @spec build_quality_options(map(), atom()) :: keyword()
  def build_quality_options(quality_profile, media_type) do
    quality_opts =
      case Map.get(quality_profile, :qualities) do
        nil -> []
        qualities when is_list(qualities) -> [preferred_qualities: qualities]
        _ -> []
      end

    rules_opts =
      case Map.get(quality_profile, :rules) do
        %{"min_ratio" => min_ratio} when is_number(min_ratio) ->
          [min_ratio: min_ratio]

        _ ->
          []
      end

    size_opts = extract_size_range(quality_profile, media_type)

    quality_opts
    |> Keyword.merge(rules_opts)
    |> Keyword.merge(size_opts)
  end

  @doc """
  Extracts size range constraints from quality standards based on media type.
  """
  @spec extract_size_range(map(), atom()) :: keyword()
  def extract_size_range(%{quality_standards: standards}, media_type)
      when is_map(standards) do
    {min_key, max_key} =
      case media_type do
        :movie -> {:movie_min_size_mb, :movie_max_size_mb}
        :episode -> {:episode_min_size_mb, :episode_max_size_mb}
      end

    min_size = Map.get(standards, min_key)
    max_size = Map.get(standards, max_key)

    case {min_size, max_size} do
      {nil, nil} -> []
      {min, nil} when is_number(min) -> [size_range: {min, nil}]
      {nil, max} when is_number(max) -> [size_range: {nil, max}]
      {min, max} when is_number(min) and is_number(max) -> [size_range: {min, max}]
      _ -> []
    end
  end

  def extract_size_range(_, _), do: []

  # -- Download Initiation --

  @doc """
  Initiates a download for a media item with the given search result.

  Accepts additional options to pass to `Downloads.initiate_download/2`,
  such as `download_reason: :upgrade`.
  """
  @spec initiate_download(MediaItem.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def initiate_download(%MediaItem{} = media_item, result, opts \\ []) do
    download_opts = Keyword.merge([media_item_id: media_item.id], opts)

    case Downloads.initiate_download(result, download_opts) do
      {:ok, download} -> {:ok, download}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Event/Stats Helpers --

  @doc """
  Builds filter statistics for search events when all results are filtered out.
  """
  @spec build_filter_stats(list(), keyword()) :: map()
  def build_filter_stats(results, ranking_opts) do
    min_seeders = Keyword.get(ranking_opts, :min_seeders, get_min_seeders())
    low_seeders = Enum.count(results, fn r -> r.seeders < min_seeders end)

    %{
      "total_results" => length(results),
      "low_seeders" => low_seeders,
      "below_quality_threshold" => length(results) - low_seeders
    }
  end

  @doc """
  Converts a map with atom keys to string keys for JSON serialization.
  """
  @spec stringify_keys(map()) :: map()
  def stringify_keys(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> stringify_keys()
  end

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  def stringify_keys(other), do: other

  # -- Private Helpers --

  defp maybe_add_option(opts, _key, nil), do: opts
  defp maybe_add_option(opts, _key, []), do: opts
  defp maybe_add_option(opts, key, value), do: Keyword.put(opts, key, value)
end
