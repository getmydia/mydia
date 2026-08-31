defmodule Mydia.Library.BatchMatcher do
  @moduledoc """
  Matches a batch of file paths while collapsing duplicate provider searches.

  `Mydia.Metadata.Cache.fetch/3` is a plain ETS get-or-compute with no
  single-flight. Matching a season concurrently therefore has every worker miss
  the cache at the same instant and issue the same search, so a twelve episode
  season costs up to `max_concurrency` identical round trips instead of one.

  This module groups a batch by anchor folder (`Mydia.Library.PathAnchor`),
  resolves one file per group, and reuses that single verdict for every other
  file beneath the same anchor rather than re-deriving it. A season folder
  with two hundred episodes is therefore one provider decision, not two
  hundred independent ones free to disagree with each other -- and because the
  anchor is found from the path alone, grouping holds even when filenames are
  too noisy for a per-file title match, which is exactly when it matters most.
  The groups themselves still run concurrently, so throughput is unchanged
  while relay traffic drops to roughly one search per distinct anchor.

  The resolver itself is a `Mydia.Library.Matcher` behaviour passed in as
  `:matcher` rather than hard-wired to `Mydia.Library.MetadataMatcher`, so
  tests can supply a deterministic stub instead of standing up a relay.

  ## Failure containment

  `match_paths/2` returns exactly one result per input path, no matter what
  happens inside a worker. `Jobs.ImportRun`'s match loop depends on that: a
  path with no result gets no `ImportCandidate` update, stays in the
  outstanding set (`Mydia.ImportCandidates.outstanding/3`), and is reselected
  by every later chunk forever. `Mydia.ImportCandidates`'s rematch path
  (`ImportCandidates.rematch/2`) depends on the same guarantee for its own
  `ImportCandidate` rows.

  Two layers keep that true. `MetadataMatcher.match_file/2` is HTTP plus
  parsing of payloads this code does not control, so a raise there is
  realistic and is caught per file, failing that one file. Anything else that
  can take a worker down (a progress callback that raises, an exit signal) is
  contained by running the workers under `Mydia.TaskSupervisor` with
  `async_stream_nolink`, which reports the crash as `{:exit, reason}` instead
  of killing the caller: plain `Task.async_stream/3` links its tasks, so a
  raising worker would take the whole coordinator down with it. The stream is
  `ordered: true` purely so an `{:exit, _}` can be zipped back to the paths it
  was working on; the emission order of the results is not part of this
  module's contract.

  The unit of containment is the group's worker, not the file. `match_group/4`
  runs an entire anchor group -- the head plus every tail file that reuses its
  result -- inside one `Task`, so a raise from `on_result` on *any* file in the
  group, head or tail, takes that whole group's worker down. `crashed_results/2`
  then replaces the group's results wholesale, marking every path in it --
  including files whose match had already succeeded -- as
  `{:error, {:matcher_crashed, reason}}`. An anchor group can be a whole show's
  worth of episodes, so this is a two-order-of-magnitude difference in blast
  radius from a single file. This matches what this section has always
  promised: worker-level, not file-level, containment for anything other than
  the matcher call itself, which stays wrapped per file in `safe_match_file/3`
  regardless of group size. The finer per-tail-file granularity the
  pre-anchor-grouping version had was incidental to that version's
  cache-warming design, where each tail file ran under its own nested
  `async_stream_nolink` -- not a guarantee this module makes. `on_result` is
  caller-supplied; today's production callback is a bare
  `Phoenix.PubSub.broadcast/3` that will not realistically raise, but a caller
  that later adds real work there (a database write, richer progress
  tracking) should know a raise anywhere in that callback now costs the whole
  anchor group it fired for, not just the one file.
  """

  require Logger

  alias Mydia.Library.{PathAnchor, ReleaseParser}

  @default_max_concurrency 10

  @type match_result :: {:ok, map()} | {:error, term()}

  @doc """
  Matches every path and returns `{path, result}` pairs, one per input path.

  Order is not guaranteed; key the results by path. A file whose match crashed
  comes back as `{:error, {:matcher_crashed, reason}}` rather than being
  dropped (see the moduledoc).

  ## Options

    * `:library_root` - required. The library path paths are relative to,
      used to find each file's anchor folder.
    * `:matcher` - required. A module implementing `Mydia.Library.Matcher`,
      used to resolve one file per group. Required rather than defaulted: a
      default would make the seam optional and let a caller silently keep the
      old per-file behaviour.
    * `:config` - metadata config, defaults to the relay default
    * `:provider` - TV metadata source for new matches
    * `:max_concurrency` - concurrent groups, default #{@default_max_concurrency}
    * `:on_result` - `fun(path, result)` called once per file, for progress
  """
  @spec match_paths([String.t()], keyword()) :: [{String.t(), match_result()}]
  def match_paths(paths, opts \\ [])

  def match_paths([], _opts), do: []

  def match_paths(paths, opts) do
    library_root = Keyword.fetch!(opts, :library_root)
    # Required, not defaulted: a default would make the seam optional and let
    # a caller silently keep the old per-file behaviour. Every call site names
    # its matcher.
    matcher = Keyword.fetch!(opts, :matcher)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    on_result = Keyword.get(opts, :on_result)
    match_opts = Keyword.take(opts, [:config, :provider])

    groups = paths |> Enum.group_by(&group_key(&1, library_root)) |> Map.values()

    Mydia.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      groups,
      fn group_paths -> match_group(group_paths, match_opts, on_result, matcher) end,
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

  # Files that name the same thing share a key. The key is the folder that
  # names the media, not the filename: two hundred episodes of one show are
  # one decision, and the grouping holds even when filenames are noisy, which
  # is exactly when per-filename grouping falls apart.
  #
  # Loose files (those with no enclosing folder under library_root, or whose
  # folders were denylisted) do not share an anchor folder and must not share
  # a single resolution. Each loose file gets its own path as the key so it
  # is matched independently on its own filename.
  defp group_key(path, library_root) do
    case PathAnchor.anchor_for(path, library_root) do
      %{anchor_path: ""} -> path
      %{cluster_key: "__root__"} -> path
      anchor -> anchor.cluster_key
    end
  end

  ## Matching

  # Resolves the series once from the anchor and applies that answer to every
  # file beneath it. The head is matched alone (as before, so the ETS cache is
  # warm) but its result is now reused rather than re-derived, which removes
  # both the redundant relay traffic and the possibility of siblings
  # disagreeing.
  defp match_group([head | tail], match_opts, on_result, matcher) do
    head_result = match_one(head, match_opts, on_result, matcher)

    tail_results =
      Enum.map(tail, fn path ->
        result = reuse(head_result, path)
        if is_function(on_result, 2), do: on_result.(path, elem(result, 1))
        result
      end)

    [head_result | tail_results]
  end

  # The anchor's verdict carries the series identity -- provider_id,
  # provider_type, title, year, match_confidence, metadata -- and that part is
  # reused as-is. Season and episode must NOT be reused: they come from the
  # filename and the season folder, not from the provider search, so
  # `parsed_info` is re-derived per tail file with the same parser
  # `MetadataMatcher.match_file/2` uses (`ReleaseParser.parse_with_path/1`)
  # instead of being copied from the head. Copying it verbatim previously sent
  # every file in a group to the head's season/episode, because
  # `MetadataEnricher` reads season/episode from `parsed_info`, not from the
  # path.
  defp reuse({_head_path, {:ok, match}}, path) do
    {path, {:ok, Map.put(match, :parsed_info, ReleaseParser.parse_with_path(path))}}
  end

  defp reuse({_head_path, {:error, reason}}, path), do: {path, {:error, reason}}

  defp match_one(path, match_opts, on_result, matcher) do
    result = safe_match_file(path, match_opts, matcher)

    if is_function(on_result, 2), do: on_result.(path, result)

    {path, result}
  end

  # Deliberately narrower than the whole worker: this wraps the one call that
  # parses payloads from an external service, so a provider returning
  # something unexpected costs only the group whose head hit it, not the
  # whole batch. This runs once per group, on the head alone -- a crash here
  # becomes {:error, {:matcher_crashed, reason}}, which `reuse/2` then hands
  # to every other file in the group exactly like a legitimate no-match
  # verdict would be. Everything outside this call is left to the stream's
  # `{:exit, _}` handling above.
  defp safe_match_file(path, match_opts, matcher) do
    matcher.match_file(path, match_opts)
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
