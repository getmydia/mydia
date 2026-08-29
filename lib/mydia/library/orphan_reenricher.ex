defmodule Mydia.Library.OrphanReenricher do
  @moduledoc """
  Decides what a scan does with the media files it finds already orphaned.

  Extracted from `Jobs.LibraryScanner`, where it was roughly forty lines of
  inline work in a module too large to test, reachable only through a job
  tagged `:external` and excluded from the default suite.

  Two things were wrong with it.

  It re-paid the relay for answers it already had. `Library.MetadataMatcher`
  never consults `Library.MatchCandidate`, so every scheduled scan issued a
  fresh match for every orphan a library had ever accumulated, including the
  ones already matched. `Library.unmatched_media_files_query/2` has skipped
  exactly those files for `Jobs.ImportRun` all along; this brings the same rule
  here.

  And it lied about its results: it discarded the outcome of each attempt and
  reported every orphan it merely located on disk as fixed, which is what
  `orphaned_files_fixed` has always counted.

  ## The decision, per orphan

      Cached rank-0 candidate      | auto_import: false | auto_import: true
      -----------------------------|--------------------|---------------------------
      Real match (provider_id set) | skip, no relay     | link from cache, no relay
      Failed, inside next_retry_at | skip               | skip
      Failed expired, or none      | fresh match         | fresh match

  `FileIngest.ingest/3` applies the confidence threshold itself, so a cached
  candidate below it comes back as `{:candidate, _}` and is simply not counted
  as fixed. There is deliberately no threshold check here.

  This module must not reference `Jobs.LibraryScanner`: the scanner passes its
  own re-enrich function in as `:reenrich`, which is also the seam the tests
  use to prove that no relay call happened.
  """

  require Logger

  alias Mydia.Library
  alias Mydia.Library.{FileIngest, MatchCandidate, MediaFile}
  alias Mydia.Metadata

  @type stats :: %{
          fixed: non_neg_integer(),
          auto_linked: non_neg_integer(),
          relay_matches: non_neg_integer()
        }

  @empty %{fixed: 0, auto_linked: 0, relay_matches: 0}

  @doc """
  Runs the decision above over every orphan, returning what actually happened.

  `file_info_by_path` maps an absolute path to the scan's file info for it. An
  orphan absent from that map is not on disk in this scan and is left alone,
  which is the one piece of the old branch's behavior worth keeping.

  ## Options

    * `:reenrich` - `(MediaFile.t(), map(), map() -> {:ok, atom()} | {:error, term()})`,
      the fresh-match path. Required in tests, defaulted by the scanner.
    * `:config` - relay config, defaults to `Metadata.default_relay_config/0`.
    * `:now` - clock for backoff comparisons, defaults to `DateTime.utc_now/0`.
  """
  @spec run(Mydia.Settings.LibraryPath.t(), [MediaFile.t()], %{String.t() => map()}, keyword()) ::
          stats()
  def run(_library_path, [], _file_info_by_path, _opts), do: @empty

  def run(library_path, orphans, file_info_by_path, opts) do
    reenrich = Keyword.fetch!(opts, :reenrich)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    candidates = Library.rank_zero_candidates_by_file_id(Enum.map(orphans, & &1.id))

    Enum.reduce(orphans, @empty, fn media_file, stats ->
      # Built from the library path argument, never MediaFile.absolute_path/1:
      # that helper returns nil with a warning when :library_path is not
      # preloaded, and these orphans arrive unpreloaded. Using it here would
      # make every lookup miss, decide every orphan :absent, and do nothing at
      # all, silently.
      file_info =
        Map.get(file_info_by_path, Path.join(library_path.path, media_file.relative_path))

      media_file
      |> decide(Map.get(candidates, media_file.id), library_path, file_info, now)
      |> apply_decision(media_file, file_info, library_path, config, reenrich)
      |> tally(stats)
    end)
  end

  ## Decision

  defp decide(_media_file, _candidate, _library_path, nil, _now), do: :absent

  defp decide(media_file, %MatchCandidate{provider_id: id} = candidate, library_path, _info, _now)
       when not is_nil(id) do
    case FileIngest.policy_for(library_path, media_file) do
      :create_items -> {:link_from_cache, candidate}
      :local_only -> :cached
    end
  end

  defp decide(_media_file, %MatchCandidate{next_retry_at: %DateTime{} = retry}, _lp, _info, now) do
    if DateTime.compare(retry, now) == :gt, do: :backoff, else: :rematch
  end

  # A NULL next_retry_at means a failure recorded before the backoff shipped.
  # Treating it as "not yet due" would strand that entire backlog, since being
  # excluded here is what stops a new failure from ever populating the column.
  defp decide(_media_file, _candidate, _library_path, _file_info, _now), do: :rematch

  ## Commit

  defp apply_decision({:link_from_cache, candidate}, media_file, _info, _lp, config, _reenrich) do
    media_file = Mydia.Repo.preload(media_file, :library_path)

    case FileIngest.ingest(media_file, MatchCandidate.to_match(candidate),
           policy: :create_items,
           config: config
         ) do
      {:linked, _item} ->
        :auto_linked

      other ->
        Logger.debug("Cached candidate did not link",
          media_file_id: media_file.id,
          outcome: inspect(other)
        )

        :unresolved
    end
  end

  defp apply_decision(:rematch, media_file, file_info, _lp, config, reenrich) do
    case reenrich.(media_file, file_info, config) do
      {:ok, :auto_linked} -> :relayed_auto_linked
      {:ok, _other} -> :relayed_fixed
      _error -> :relayed_unresolved
    end
  end

  defp apply_decision(skipped, _media_file, _info, _lp, _config, _reenrich), do: skipped

  ## Tally

  defp tally(:auto_linked, stats),
    do: %{stats | fixed: stats.fixed + 1, auto_linked: stats.auto_linked + 1}

  defp tally(:relayed_auto_linked, stats),
    do: %{
      stats
      | fixed: stats.fixed + 1,
        auto_linked: stats.auto_linked + 1,
        relay_matches: stats.relay_matches + 1
    }

  defp tally(:relayed_fixed, stats),
    do: %{stats | fixed: stats.fixed + 1, relay_matches: stats.relay_matches + 1}

  defp tally(:relayed_unresolved, stats),
    do: %{stats | relay_matches: stats.relay_matches + 1}

  # :absent, :cached, :backoff and :unresolved all changed nothing.
  defp tally(_outcome, stats), do: stats
end
