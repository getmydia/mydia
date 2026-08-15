defmodule Mydia.Library.BatchMatcher do
  @moduledoc """
  Matches a batch of file paths while collapsing duplicate provider searches.

  `Mydia.Metadata.Cache.fetch/3` is a plain ETS get-or-compute with no
  single-flight. Matching a season concurrently therefore has every worker miss
  the cache at the same instant and issue the same search, so a twelve episode
  season costs up to `max_concurrency` identical round trips instead of one.

  This module groups a batch by normalized search title, matches one file per
  group first so the cache is warm, then fans the rest of that group out. The
  groups themselves still run concurrently, so throughput is unchanged while
  relay traffic drops to roughly one search per distinct title.
  """

  require Logger

  alias Mydia.Library.MetadataMatcher
  alias Mydia.Library.ReleaseParser

  @default_max_concurrency 10

  @type match_result :: {:ok, map()} | {:error, term()}

  @doc """
  Matches every path and returns `{path, result}` pairs.

  Order is not guaranteed; key the results by path.

  ## Options

    * `:config` - metadata config, defaults to the relay default
    * `:provider` - TV metadata source for new matches
    * `:max_concurrency` - concurrent groups, default #{@default_max_concurrency}
    * `:on_result` - `fun(path, result)` called once per file, for progress
  """
  @spec match_paths([String.t()], keyword()) :: [{String.t(), match_result()}]
  def match_paths(paths, opts \\ [])

  def match_paths([], _opts), do: []

  def match_paths(paths, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    on_result = Keyword.get(opts, :on_result)
    match_opts = Keyword.take(opts, [:config, :provider])

    paths
    |> Enum.group_by(&group_key/1)
    |> Task.async_stream(
      fn {_key, group_paths} -> match_group(group_paths, match_opts, on_result) end,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end

  ## Grouping

  # Files that will search for the same thing share a key. Parsing is cheap and
  # local, so doing it twice (here and inside match_file/2) costs nothing next
  # to one avoided HTTP round trip.
  defp group_key(path) do
    parsed = ReleaseParser.parse_with_path(path)

    case parsed.title do
      nil -> {:unparsed, path}
      title -> {parsed.type, MetadataMatcher.normalize_search_query(title)}
    end
  end

  ## Matching

  # The head is matched alone so its search populates the ETS cache. Only then
  # is the tail fanned out, where every one of them is a cache hit.
  defp match_group([head | tail], match_opts, on_result) do
    head_result = match_one(head, match_opts, on_result)

    tail_results =
      tail
      |> Task.async_stream(
        fn path -> match_one(path, match_opts, on_result) end,
        max_concurrency: @default_max_concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    [head_result | tail_results]
  end

  defp match_one(path, match_opts, on_result) do
    result = MetadataMatcher.match_file(path, match_opts)

    if is_function(on_result, 2), do: on_result.(path, result)

    {path, result}
  end
end
