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

  ## Failure containment

  `match_paths/2` returns exactly one result per input path, no matter what
  happens inside a worker. `Jobs.ImportRun`'s match loop depends on that: a
  path with no result gets no `MatchCandidate`, stays in the outstanding set,
  and is reselected by every later chunk forever.

  Two layers keep that true. `MetadataMatcher.match_file/2` is HTTP plus
  parsing of payloads this code does not control, so a raise there is
  realistic and is caught per file, failing that one file. Anything else that
  can take a worker down (a progress callback that raises, an exit signal) is
  contained by running the workers under `Mydia.TaskSupervisor` with
  `async_stream_nolink`, which reports the crash as `{:exit, reason}` instead
  of killing the caller: plain `Task.async_stream/3` links its tasks, so a
  raising worker would take the whole coordinator down with it. Both streams
  are `ordered: true` purely so an `{:exit, _}` can be zipped back to the
  paths it was working on; the emission order of the results is not part of
  this module's contract.
  """

  require Logger

  alias Mydia.Library.MetadataMatcher
  alias Mydia.Library.ReleaseParser

  @default_max_concurrency 10

  @type match_result :: {:ok, map()} | {:error, term()}

  @doc """
  Matches every path and returns `{path, result}` pairs, one per input path.

  Order is not guaranteed; key the results by path. A file whose match crashed
  comes back as `{:error, {:matcher_crashed, reason}}` rather than being
  dropped (see the moduledoc).

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

    groups = paths |> Enum.group_by(&group_key/1) |> Map.values()

    Mydia.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      groups,
      fn group_paths -> match_group(group_paths, match_opts, on_result) end,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.zip(groups)
    |> Enum.flat_map(fn
      {{:ok, results}, _group_paths} -> results
      {{:exit, reason}, group_paths} -> crashed_results(group_paths, reason)
    end)
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
      Mydia.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        tail,
        fn path -> match_one(path, match_opts, on_result) end,
        max_concurrency: @default_max_concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.zip(tail)
      |> Enum.flat_map(fn
        {{:ok, result}, _path} -> [result]
        {{:exit, reason}, path} -> crashed_results([path], reason)
      end)

    [head_result | tail_results]
  end

  defp match_one(path, match_opts, on_result) do
    result = safe_match_file(path, match_opts)

    if is_function(on_result, 2), do: on_result.(path, result)

    {path, result}
  end

  # Deliberately narrower than the whole worker: this wraps the one call that
  # parses payloads from an external service, so a provider returning
  # something unexpected costs the file that hit it and nothing else. The
  # group's remaining files still get their own searches (one cache miss each,
  # which is the correct trade against losing a whole season to one bad
  # response). Everything outside this call is left to the stream's `{:exit,
  # _}` handling above.
  defp safe_match_file(path, match_opts) do
    MetadataMatcher.match_file(path, match_opts)
  rescue
    error ->
      Logger.error("Matching a file raised, recording it as a failed match",
        path: path,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, {:matcher_crashed, Exception.message(error)}}
  catch
    kind, value ->
      Logger.error("Matching a file did not return, recording it as a failed match",
        path: path,
        kind: kind,
        reason: inspect(value)
      )

      {:error, {:matcher_crashed, value}}
  end

  # A crashed worker still owes a result for every path it was holding. Losing
  # them would leave those files with no candidate and no parent, which is
  # exactly the state `Jobs.ImportRun`'s match loop reselects forever.
  defp crashed_results(paths, reason) do
    Logger.error("A batch match worker crashed, failing its files instead of the run",
      files: length(paths),
      example_path: List.first(paths),
      reason: inspect(reason)
    )

    Enum.map(paths, &{&1, {:error, {:matcher_crashed, reason}}})
  end
end
