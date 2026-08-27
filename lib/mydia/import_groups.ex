defmodule Mydia.ImportGroups do
  @moduledoc """
  Query and decision surface for import groups.

  Everything the review page reads goes through here, and every count comes
  from SQL rather than from walking a loaded collection. That is the property
  that makes the page independent of library size: the working set is one page
  of groups, never one row per file.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Accounts.Scope
  alias Mydia.Library
  alias Mydia.Library.ImportGroup
  alias Mydia.Library.ImportRun
  alias Mydia.Library.MatchCandidate
  alias Mydia.Library.MediaFile
  alias Mydia.Library.PathAnchor
  alias Mydia.Library.SelectionScope
  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Metadata
  alias Mydia.Repo
  alias Mydia.Settings

  @auto_accept_threshold 0.85
  @default_page_size 50
  @upsert_chunk 500

  # The bind-parameter cap `stamp_members/2` guards against. PostgreSQL caps
  # bound parameters at 65,535 and SQLite at 32,766; an unbounded `id in ^ids`
  # is a crash at scale on either adapter, not just slow.
  @id_bind_chunk 500

  @doc """
  The confidence at or above which a group is considered settled.

  Calibrated against the production library on 2026-08-17, whose candidates
  cluster at 0.65-0.70 and 0.90-1.00 with nothing in between. Every value in
  [0.75, 0.89] produces the same partition there, so this is a robust choice
  rather than a tuned one. `Mydia.Library.FileIngest` reads the same number.
  """
  @spec auto_accept_threshold() :: float()
  def auto_accept_threshold, do: @auto_accept_threshold

  @doc """
  Clears the derived scan and review state for one library path.

  That means the cached match candidates as well as the groups rolled up from
  them, so the next scan re-matches from scratch instead of reproducing the
  previous scan's verdicts. Clearing the groups alone did the latter, which is
  how a shipped matcher fix could fail to reach an already-scanned library.

  Imported media files are preserved, links and all: a completed import is not
  scan state. Active scans are refused so their coordinator cannot recreate
  groups while the clear is in progress.

  Returns the number of groups and candidates removed.
  """
  @spec clear_for_library(binary()) ::
          {:ok, %{groups: non_neg_integer(), candidates: non_neg_integer()}}
          | {:error, :active_run}
  def clear_for_library(library_path_id) do
    result =
      Repo.transaction(fn ->
        active_statuses = ImportRun.active_statuses()

        if Repo.exists?(
             from(r in ImportRun,
               where: r.library_path_id == ^library_path_id and r.status in ^active_statuses
             )
           ) do
          Repo.rollback(:active_run)
        end

        # Before the groups, because the groups are only a rollup of these.
        # Leaving them behind is what made a clear-then-rescan reproduce the
        # previous scan's verdicts exactly -- see
        # `Library.delete_match_candidates_for_library/1`.
        {candidate_count, _} = Library.delete_match_candidates_for_library(library_path_id)

        {group_count, _} =
          ImportGroup
          |> where([g], g.library_path_id == ^library_path_id)
          |> Repo.delete_all()

        ImportRun
        |> where([r], r.library_path_id == ^library_path_id)
        |> Repo.delete_all()

        %{groups: group_count, candidates: candidate_count}
      end)

    with {:ok, counts} <- result do
      Phoenix.PubSub.broadcast(Mydia.PubSub, "import_groups:#{library_path_id}", {
        :import_groups_changed,
        library_path_id
      })

      {:ok, counts}
    end
  end

  @doc """
  Which review band a group falls into.

  Disagreement beats confidence: if the group's members did not all resolve the
  same provider id, a human should look at it however certain each individual
  file was.

  A `provider_type: "local"` group is never `:ready`, whatever its
  `min_confidence`: "ready" means ready to *accept*, `accept/1` hands a
  provider match to `FileIngest`, and a local group has none -- its
  `provider_id` is the synthetic `"local-" <> item.id` marker
  `ImportGroups.create_local_show/1` stamps to guard against a second call, not
  a real match. Without this clause, a leftover orphaned member could later
  acquire its own high-confidence `MatchCandidate` (title matching is
  independent of episode-number parsing), a rescan would raise the group's
  `min_confidence` above the threshold, and the group would drift into
  `:ready`, get accepted, and then `accepted_groups/1` would exclude it
  forever -- stranding it exactly the way an `"applied"` local group used to.
  """
  @spec band(ImportGroup.t()) :: :ready | :needs_attention | :no_match
  def band(%ImportGroup{provider_id: nil}), do: :no_match
  def band(%ImportGroup{provider_type: "local"}), do: :needs_attention

  def band(%ImportGroup{} = group) do
    cond do
      disagreement?(group) -> :needs_attention
      is_nil(group.min_confidence) -> :needs_attention
      group.min_confidence >= @auto_accept_threshold -> :ready
      true -> :needs_attention
    end
  end

  defp disagreement?(%ImportGroup{evidence: %{"disagreement" => true}}), do: true
  defp disagreement?(_), do: false

  @doc "Counts pending groups per band for one library path."
  @spec band_counts(binary()) :: %{
          ready: non_neg_integer(),
          needs_attention: non_neg_integer(),
          no_match: non_neg_integer(),
          total: non_neg_integer()
        }
  def band_counts(library_path_id) do
    # Folded in Elixir rather than aggregated in SQL: `band/1` reads the JSON
    # evidence column, and CLAUDE.md forbids SQL aggregates over the kinds of
    # values this would otherwise need to CASE over on two adapters.
    #
    # Deliberately hardcodes "pending" rather than taking a status: this is
    # the number the nav badge and the Ready/Needs attention/No match chips
    # are built from, and both have to keep meaning "needs a decision".
    # `count_by_status/2` below is the Ignored chip's own count, kept
    # separate rather than folded in here for exactly that reason.
    ImportGroup
    |> for_status("pending")
    |> for_library(library_path_id)
    |> select([g], %{
      provider_id: g.provider_id,
      provider_type: g.provider_type,
      min_confidence: g.min_confidence,
      evidence: g.evidence
    })
    |> Repo.all()
    |> Enum.reduce(%{ready: 0, needs_attention: 0, no_match: 0, total: 0}, fn row, acc ->
      key = band(struct(ImportGroup, row))

      acc
      |> Map.update!(key, &(&1 + 1))
      |> Map.update!(:total, &(&1 + 1))
    end)
  end

  @doc """
  Total pending groups across every library, for the navigation badge.

  A plain SQL count, deliberately not `band_counts/1`: that one loads every
  pending row to fold bands in Elixir, and this runs on every authenticated
  LiveView mount. Hardcodes "pending" for the same reason `band_counts/1`
  does -- the badge means "needs a decision", not "every group that exists".
  """
  @spec count_pending() :: non_neg_integer()
  def count_pending do
    ImportGroup
    |> for_status("pending")
    |> Repo.aggregate(:count)
  end

  @doc """
  How many groups of one status exist for a library path.

  Used for the Ignored filter chip's count, which has to stay a call of its
  own rather than a key `band_counts/1` folds in: `band/1`'s bands are a
  partition of confidence, not of status, and an ignored group's own band is
  usually still meaningful (an ignored :ready group is still :ready) --
  conflating the two would make "how many groups are ignored" depend on
  which bands happened to exist among them.
  """
  @spec count_by_status(binary(), String.t()) :: non_neg_integer()
  def count_by_status(library_path_id, status) do
    ImportGroup
    |> for_library(library_path_id)
    |> for_status(status)
    |> Repo.aggregate(:count)
  end

  @doc """
  One keyset page of groups, newest-largest first.

  Returns `{groups, cursor}`; `cursor` is nil when the page is the last one.
  Pass the cursor back as `:after`. Ordering is `{file_count desc, id asc}`, so
  the biggest blast radius is decided first and the first screenful of
  decisions covers most of the library's files.

  `:status` defaults to `"pending"`, the review page's normal view. The
  Ignored filter passes `status: "ignored"` to read the same page shape back
  for groups a human has already dismissed -- see `ImportGroups.restore/1`
  for how one of them gets back out.
  """
  @spec page(binary(), keyword()) :: {[ImportGroup.t()], term() | nil}
  def page(library_path_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)
    status = Keyword.get(opts, :status, "pending")

    groups =
      library_path_id
      |> base_query(status)
      |> apply_band(Keyword.get(opts, :band))
      |> apply_search(Keyword.get(opts, :q))
      |> apply_cursor(Keyword.get(opts, :after))
      |> order_by([g], desc: g.file_count, asc: g.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    case Enum.split(groups, limit) do
      {page, []} -> {page, nil}
      {page, _extra} -> {page, cursor_for(List.last(page))}
    end
  end

  @doc """
  Recomputes every group for one library path from its unresolved files.

  Idempotent and resumable. A group that already exists keeps its `status` and
  `decided_at`, so recomputing after a rescan never un-decides a human's answer;
  only the rollup columns are refreshed.

  Processes in keyset chunks of #{@upsert_chunk} files so a 200,000-file library
  never materialises at once.
  """
  @spec upsert_for_library(Mydia.Settings.LibraryPath.t(), keyword()) ::
          {:ok, %{groups: non_neg_integer(), files: non_neg_integer()}}
  def upsert_for_library(library_path, opts \\ []) do
    run_id = Keyword.get(opts, :import_run_id)

    {rollups, file_count} = collect_rollups(library_path)

    group_ids =
      rollups
      |> Enum.map(fn {cluster_key, rollup} ->
        {cluster_key, write_group(library_path, cluster_key, rollup, run_id)}
      end)
      |> Map.new()

    stamp_members(library_path, group_ids)
    prune_obsolete_groups(library_path.id)

    {:ok, %{groups: map_size(group_ids), files: file_count}}
  end

  defp prune_obsolete_groups(library_path_id) do
    referenced_group_ids_query =
      MediaFile
      |> where([f], f.library_path_id == ^library_path_id)
      |> where(
        [f],
        is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at) and
          not is_nil(f.import_group_id)
      )
      |> select([f], f.import_group_id)
      |> distinct(true)

    from(g in ImportGroup,
      where: g.library_path_id == ^library_path_id and g.status == "pending",
      where: g.id not in subquery(referenced_group_ids_query)
    )
    |> Repo.delete_all()
  end

  defp base_query(library_path_id, status) do
    ImportGroup
    |> for_library(library_path_id)
    |> for_status(status)
  end

  # Shared by base_query/2, band_counts/1, count_pending/0 and
  # count_by_status/2, which each used to spell `g.status == "..."` out
  # separately -- threading the value through here instead of duplicating the
  # predicate is what makes it possible to tell at a glance that "pending"
  # means the same thing in all four places.
  defp for_status(query, status), do: where(query, [g], g.status == ^status)

  defp for_library(query, library_path_id),
    do: where(query, [g], g.library_path_id == ^library_path_id)

  defp apply_band(query, nil), do: query
  defp apply_band(query, :all), do: query

  defp apply_band(query, :no_match), do: where(query, [g], is_nil(g.provider_id))

  defp apply_band(query, :ready) do
    # A `provider_type: "local"` group's `provider_id` is a synthetic marker,
    # not a real match -- see band/1's doc for why it can never be :ready
    # however high its min_confidence. Kept in step with SelectionScope's own
    # `:ready` predicate by the cross-module parity test in
    # selection_scope_test.exs.
    where(
      query,
      [g],
      not is_nil(g.provider_id) and g.min_confidence >= ^@auto_accept_threshold and
        (is_nil(g.provider_type) or g.provider_type != "local")
    )
  end

  defp apply_band(query, :needs_attention) do
    where(
      query,
      [g],
      not is_nil(g.provider_id) and g.min_confidence < ^@auto_accept_threshold
    )
  end

  defp apply_search(query, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"

    where(
      query,
      [g],
      fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", g.anchor_path, ^like)
    )
  end

  defp apply_search(query, _), do: query

  # Backslash must be escaped first, or the escapes added on the next two
  # lines get escaped again. `_` is LIKE's single-character wildcard and shows
  # up constantly in release folder names, so it needs the same treatment as
  # `%`. The `ESCAPE '\'` clause above is what makes this backslash convention
  # take effect: PostgreSQL treats backslash as the implicit LIKE escape, but
  # SQLite has no escape character at all unless one is declared.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {file_count, id}) do
    where(
      query,
      [g],
      g.file_count < ^file_count or (g.file_count == ^file_count and g.id > ^id)
    )
  end

  defp cursor_for(%ImportGroup{file_count: file_count, id: id}), do: {file_count, id}

  # Streams unresolved files in id-keyset chunks and folds them into one rollup
  # per cluster key. Only the columns the rollup needs are selected: whole
  # MediaFile structs drag the blob columns and are what made the old inbox
  # query unusable.
  defp collect_rollups(library_path) do
    library_path
    |> stream_unresolved()
    |> Enum.reduce({%{}, 0}, fn row, {acc, count} ->
      {fold_row(row, acc, library_path), count + 1}
    end)
  end

  defp unresolved_chunk(library_path_id, nil, limit),
    do: unresolved_base(library_path_id) |> limit(^limit) |> Repo.all()

  defp unresolved_chunk(library_path_id, last_id, limit) do
    unresolved_base(library_path_id)
    |> where([f], f.id > ^last_id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp unresolved_base(library_path_id) do
    MediaFile
    |> where([f], f.library_path_id == ^library_path_id)
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at))
    |> join(:left, [f], c in MatchCandidate, on: c.media_file_id == f.id and c.rank == 0)
    |> order_by([f], asc: f.id)
    |> select([f, c], %{
      id: f.id,
      relative_path: f.relative_path,
      provider_id: c.provider_id,
      provider_type: c.provider_type,
      title: c.title,
      year: c.year,
      media_type: c.media_type,
      confidence: c.confidence,
      parsed_info: c.parsed_info
    })
  end

  defp movie_row?(row, library_path) do
    library_path.type == :movies or row.media_type == "movie"
  end

  defp cluster_key_for(row, library_path) do
    if movie_row?(row, library_path) do
      "file-" <> row.id
    else
      PathAnchor.anchor_for(
        Path.join(library_path.path, row.relative_path),
        library_path.path
      ).cluster_key
    end
  end

  defp fold_row(row, acc, library_path) do
    if movie_row?(row, library_path) do
      key = "file-" <> row.id
      title = row.title || Path.rootname(Path.basename(row.relative_path || ""))

      Map.put(
        acc,
        key,
        %{
          anchor_path: row.relative_path,
          display_title: title,
          file_count: 1,
          numbered_count: 0,
          provider_ids: MapSet.new(List.wrap(row.provider_id)),
          provider_id: row.provider_id,
          provider_type: row.provider_type,
          suggested_title: row.title,
          suggested_year: row.year,
          media_type: "movie",
          min_confidence: row.confidence,
          seasons: MapSet.new()
        }
      )
    else
      anchor =
        PathAnchor.anchor_for(Path.join(library_path.path, row.relative_path), library_path.path)

      Map.update(
        acc,
        anchor.cluster_key,
        initial_rollup(anchor, row),
        &merge_rollup(&1, anchor, row)
      )
    end
  end

  defp initial_rollup(anchor, row) do
    %{
      anchor_path: anchor.anchor_path,
      display_title: display_title(anchor),
      file_count: 1,
      numbered_count: numbered(row),
      provider_ids: MapSet.new(List.wrap(row.provider_id)),
      provider_id: row.provider_id,
      provider_type: row.provider_type,
      suggested_title: row.title,
      suggested_year: row.year,
      media_type: row.media_type,
      min_confidence: row.confidence,
      seasons: MapSet.new(List.wrap(anchor.season_hint || season_of(row)))
    }
  end

  defp merge_rollup(rollup, anchor, row) do
    %{
      rollup
      | file_count: rollup.file_count + 1,
        numbered_count: rollup.numbered_count + numbered(row),
        provider_ids: maybe_put(rollup.provider_ids, row.provider_id),
        provider_id: rollup.provider_id || row.provider_id,
        provider_type: rollup.provider_type || row.provider_type,
        suggested_title: rollup.suggested_title || row.title,
        suggested_year: rollup.suggested_year || row.year,
        media_type: rollup.media_type || row.media_type,
        min_confidence: min_conf(rollup.min_confidence, row.confidence),
        seasons: maybe_put(rollup.seasons, anchor.season_hint || season_of(row))
    }
  end

  defp maybe_put(set, nil), do: set
  defp maybe_put(set, value), do: MapSet.put(set, value)

  defp min_conf(nil, b), do: b
  defp min_conf(a, nil), do: a
  defp min_conf(a, b), do: min(a, b)

  defp numbered(%{parsed_info: %{"episodes" => [_ | _]}}), do: 1
  defp numbered(_), do: 0

  defp season_of(%{parsed_info: %{"season" => season}}) when is_integer(season), do: season
  defp season_of(_), do: nil

  defp display_title(%{anchor_path: ""}), do: "Loose files"
  defp display_title(%{anchor_path: anchor_path}), do: Path.basename(anchor_path)

  defp write_group(library_path, cluster_key, rollup, run_id) do
    disagreement = MapSet.size(rollup.provider_ids) > 1

    attrs = %{
      library_path_id: library_path.id,
      import_run_id: run_id,
      anchor_path: rollup.anchor_path,
      cluster_key: cluster_key,
      display_title: rollup.display_title,
      file_count: rollup.file_count,
      unresolved_count: rollup.file_count,
      numbered_count: rollup.numbered_count,
      media_type: rollup.media_type,
      provider_type: rollup.provider_type,
      provider_id: rollup.provider_id,
      suggested_title: rollup.suggested_title,
      suggested_year: rollup.suggested_year,
      # A disagreeing group carries no min_confidence, which is what keeps the
      # SQL `:ready` predicate in page/2 exact without teaching it to read JSON.
      min_confidence: if(disagreement, do: nil, else: rollup.min_confidence),
      evidence: %{
        "kind" => evidence_kind(rollup, disagreement),
        "candidates" => MapSet.size(rollup.provider_ids),
        "disagreement" => disagreement
      },
      season_span: MapSet.to_list(rollup.seasons),
      status: "pending"
    }

    existing =
      Repo.get_by(ImportGroup, library_path_id: library_path.id, cluster_key: cluster_key)

    # A brand new group starts "pending". An existing group has :status
    # stripped here before the changeset runs, so cast/3 sees no change for it
    # and the row's current status (set by a human, or by an earlier run of
    # this same function) is left exactly as it was: recomputing must never
    # un-decide a human's accepted/ignored call.
    #
    # A locally-created group (`ImportGroups.create_local_show/1`) gets the
    # same treatment for `provider_type` and `provider_id`: that synthetic
    # marker *is* the human's decision for a show no provider carries, same
    # as `:status` is for accept/ignore, and a routine rescan must not
    # un-decide it either. Without this, the leftover unresolved file in a
    # partially-linked local group is still genuinely unresolved, so the next
    # rescan folds it back into a fresh rollup with no matched candidate,
    # resets `provider_type`/`provider_id` to nil, and a second click on
    # "Create show from folder" no longer sees the marker and mints a second,
    # empty `MediaItem`.
    #
    # A provider-*matched* group is deliberately NOT special-cased here: its
    # provider fields should keep refreshing on a rescan, because a match can
    # legitimately improve. Only `provider_type == "local"` is preserved --
    # everything else on a local group (`file_count`, `unresolved_count`,
    # `numbered_count`, `min_confidence`, `season_span`) keeps recomputing
    # from the fresh rollup, so if more files land in that folder later, the
    # rescan still notices them.
    attrs =
      cond do
        is_nil(existing) ->
          attrs

        existing.provider_type == "local" and existing.status == "applied" ->
          Map.drop(attrs, [:provider_type, :provider_id])

        existing.provider_type == "local" ->
          Map.drop(attrs, [:status, :provider_type, :provider_id])

        existing.status == "applied" ->
          attrs

        true ->
          Map.drop(attrs, [:status])
      end

    {:ok, group} =
      (existing || %ImportGroup{})
      |> ImportGroup.changeset(attrs)
      |> Repo.insert_or_update()

    group.id
  end

  defp evidence_kind(%{provider_id: nil}, _), do: "none"
  defp evidence_kind(_, true), do: "fuzzy"
  defp evidence_kind(%{min_confidence: c}, _) when is_float(c) and c >= 0.99, do: "exact_title"
  defp evidence_kind(_, _), do: "fuzzy"

  # Stamps import_group_id in ONE streaming pass over the unresolved set.
  #
  # The obvious shape, "for each group, find its files", is O(groups * files):
  # on a 200,000-file library with 3,000 groups that is 600 million anchor
  # computations and 3,000 full table scans. Instead this walks the files once,
  # buffers ids per group, and flushes a buffer as soon as it reaches the bind
  # cap. Total work is O(files) and no buffer exceeds @id_bind_chunk rows.
  defp stamp_members(library_path, group_ids) do
    library_path
    |> stream_unresolved()
    |> Enum.reduce(%{}, fn row, buffers ->
      cluster_key = cluster_key_for(row, library_path)

      case Map.fetch(group_ids, cluster_key) do
        :error ->
          buffers

        {:ok, group_id} ->
          buffer = [row.id | Map.get(buffers, group_id, [])]

          if length(buffer) >= @id_bind_chunk do
            flush(group_id, buffer)
            Map.delete(buffers, group_id)
          else
            Map.put(buffers, group_id, buffer)
          end
      end
    end)
    |> Enum.each(fn {group_id, buffer} -> flush(group_id, buffer) end)
  end

  defp flush(_group_id, []), do: :ok

  defp flush(group_id, ids) do
    MediaFile
    |> where([f], f.id in ^ids)
    |> Repo.update_all(set: [import_group_id: group_id])
  end

  # The same keyset walk collect_rollups/1 uses, exposed as a Stream so both
  # passes share one definition of "unresolved, in id order, in chunks".
  defp stream_unresolved(library_path) do
    Stream.resource(
      fn -> nil end,
      fn
        :done ->
          {:halt, :done}

        last_id ->
          rows = unresolved_chunk(library_path.id, last_id, @upsert_chunk)

          cond do
            rows == [] -> {:halt, :done}
            length(rows) < @upsert_chunk -> {rows, :done}
            true -> {rows, List.last(rows).id}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Marks a selection accepted and enqueues the commit.

  The status flip is guarded on `status == "pending"`, so two sessions racing on
  the same group produce one winner and a zero count for the loser rather than a
  double commit.

  Returns `{:error, reason}` when the flip succeeded but the enqueue did not,
  so a caller never hears "success" for a selection now `accepted` with no
  worker enqueued to commit it.
  """
  @spec accept(SelectionScope.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def accept(%SelectionScope{} = scope) do
    scope
    |> SelectionScope.to_query()
    |> accept_query(scope.library_path_id)
  end

  @doc """
  Accepts every pending provider-matched group for one library path.

  Unmatched and synthetic local groups are excluded because the apply worker
  cannot link them. Confidence is deliberately not filtered: this is the
  explicit human override represented by the Import All control.
  """
  @spec accept_all_matched(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def accept_all_matched(library_path_id) do
    ImportGroup
    |> where(
      [g],
      g.library_path_id == ^library_path_id and g.status == "pending" and
        not is_nil(g.provider_id) and
        (is_nil(g.provider_type) or g.provider_type != "local")
    )
    |> accept_query(library_path_id)
  end

  defp accept_query(query, library_path_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      query
      |> Repo.update_all(set: [status: "accepted", decided_at: now, updated_at: now])

    if count > 0 do
      case %{"library_path_id" => library_path_id}
           |> Mydia.Jobs.ApplyImportGroups.new()
           |> insert_job() do
        {:ok, _job} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, count}
    end
  end

  @doc "Marks a selection ignored. No files are touched."
  @spec ignore(SelectionScope.t()) :: {:ok, non_neg_integer()}
  def ignore(%SelectionScope{} = scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      scope
      |> SelectionScope.to_query()
      |> Repo.update_all(set: [status: "ignored", decided_at: now, updated_at: now])

    {:ok, count}
  end

  @doc """
  Restores one or more ignored groups to "pending".

  Accepts either a single group binary id, or a `%SelectionScope{}`.
  Guarded on `status == "ignored"` rather than an unconditional update, so a
  stale or double-clicked Restore is a silent no-op (`{:ok, 0}`).
  """
  @spec restore(SelectionScope.t() | binary()) :: {:ok, non_neg_integer()}
  def restore(%SelectionScope{} = scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      scope
      |> SelectionScope.to_query()
      |> where([g], g.status == "ignored")
      |> Repo.update_all(set: [status: "pending", decided_at: nil, updated_at: now])

    {:ok, count}
  end

  def restore(group_id) when is_binary(group_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      ImportGroup
      |> where([g], g.id == ^group_id and g.status == "ignored")
      |> Repo.update_all(set: [status: "pending", decided_at: nil, updated_at: now])

    {:ok, count}
  end

  @doc "Re-runs metadata matching for media files in the selected groups."
  @spec rematch(SelectionScope.t(), keyword()) :: {:ok, non_neg_integer()}
  def rematch(%SelectionScope{} = scope, opts \\ []) do
    with {:ok, stats} <- rematch_with_stats(scope, opts) do
      {:ok, stats.groups}
    end
  end

  @doc "Re-matches a selection in bounded pages and reports file-level failures."
  @spec rematch_with_stats(SelectionScope.t(), keyword()) ::
          {:ok,
           %{groups: non_neg_integer(), files: non_neg_integer(), failures: non_neg_integer()}}
  def rematch_with_stats(%SelectionScope{} = scope, opts \\ []) do
    library_path = Settings.get_library_path!(scope.library_path_id)
    matcher = Keyword.get(opts, :matcher, Mydia.Library.MetadataMatcher)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    page_size = Keyword.get(opts, :page_size, 250)

    stats =
      rematch_pages(scope, library_path, matcher, config, page_size, nil, %{files: 0, failures: 0})

    upsert_for_library(library_path)

    {:ok, Map.put(stats, :groups, SelectionScope.count(scope))}
  end

  defp rematch_pages(scope, library_path, matcher, config, page_size, after_id, stats) do
    rows = rematch_page(scope, page_size, after_id)

    case rows do
      [] ->
        stats

      rows ->
        page_stats = rematch_rows(rows, library_path, matcher, config)
        stats = Map.merge(stats, page_stats, fn _key, left, right -> left + right end)
        rematch_pages(scope, library_path, matcher, config, page_size, List.last(rows).id, stats)
    end
  end

  defp rematch_page(scope, page_size, after_id) do
    MediaFile
    |> where([f], f.library_path_id == ^scope.library_path_id)
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at))
    |> join(:inner, [f], g in subquery(SelectionScope.to_query(scope)),
      on: f.import_group_id == g.id
    )
    |> then(fn query ->
      if after_id, do: where(query, [f], f.id > ^after_id), else: query
    end)
    |> order_by([f], asc: f.id)
    |> limit(^page_size)
    |> select([f], %{id: f.id, relative_path: f.relative_path})
    |> Repo.all()
  end

  defp rematch_rows(rows, library_path, matcher, config) do
    rows_by_path = Map.new(rows, &{Path.join(library_path.path, &1.relative_path), &1.id})

    rows_by_path
    |> Map.keys()
    |> Mydia.Library.BatchMatcher.match_paths(
      library_root: library_path.path,
      matcher: matcher,
      config: config
    )
    |> Enum.reduce(%{files: 0, failures: 0}, fn {path, outcome}, stats ->
      case rematch_file(rows_by_path[path], outcome, config) do
        :ok -> %{stats | files: stats.files + 1}
        :error -> %{stats | failures: stats.failures + 1}
      end
    end)
  end

  defp rematch_file(media_file_id, outcome, config) do
    match_data =
      case outcome do
        {:ok, data} -> data
        {:error, reason} when reason in [:no_match, :no_matches_found, :unknown_media_type] -> nil
        {:error, _reason} -> :failed
      end

    with match_data when match_data != :failed <- match_data,
         %MediaFile{} = media_file <- Repo.get(MediaFile, media_file_id) do
      case Mydia.Library.FileIngest.ingest(media_file, match_data,
             policy: :local_only,
             config: config
           ) do
        {:error, _reason} -> :error
        _success -> :ok
      end
    else
      _failure -> :error
    end
  rescue
    error ->
      Logger.error("Re-matching an import file failed",
        media_file_id: media_file_id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end

  @doc """
  Applies a human-picked metadata match to a whole group: the "Change match"
  / "Identify" action.

  On galactica -- the library the whole 0.85 threshold is calibrated against
  -- `Patamuse (2018)` matched "The Peter Potamus Show" at 0.703 and
  `Les contes de la tortue (2025)` matched "Eat the Rich: The GameStop Saga"
  at 0.699. Before this there was no way to correct either without either
  accepting the wrong show or hiding the folder forever with Ignore.

  `match` is a plain map built from a chosen
  `Mydia.Metadata.Structs.SearchResult`: `%{provider_id:, provider_type:,
  title:, year:, media_type:}`. Every value is stringified here regardless of
  what the caller passed (an atom `provider_type`/`media_type` is the normal
  case, mirroring `MetadataMatcher`'s own `if result.provider == :tvdb, do:
  :tvdb, else: :tmdb` convention), since both `ImportGroup` and
  `MatchCandidate` store these as text columns.

  This updates two things, not one:

    * The group's own suggested fields, `min_confidence` (set to 1.0 -- a
      human's pick is at least as trustworthy as an automatic match, and the
      whole point of correcting a group is that it reads `:ready`
      afterwards, not merely "still needs attention, differently") and
      `evidence` (kind `"manual"`).
    * Every unresolved member's rank-0 `MatchCandidate`. This is not
      optional: `ApplyImportGroups.ingest_member/2` builds each file's match
      from `candidate.provider_id || group.provider_id` -- candidate first --
      so updating only the group would leave the worker reading each
      member's stale, wrong candidate and committing that instead of the
      correction. `parsed_info` (each member's own season/episode) is left
      alone; only the provider identity and title/year/media_type change.

  Refuses (`{:error, :not_pending}`) a group that is not `"pending"`:
  `accept/1`, `ignore/1` and the worker have all already moved a
  non-pending group somewhere a rewritten match would race.

  Refuses (`{:error, :not_found}`), rather than raising, a group id that no
  longer exists -- the render-then-click race also handled by
  `open_match_search`'s `Repo.get/2`: another session or a concurrent run can
  remove the group between the page rendering the "Change match" button and
  the reviewer picking a result.
  """
  @spec change_match(binary(), map()) ::
          {:ok, ImportGroup.t()} | {:error, :not_pending} | {:error, :not_found}
  def change_match(group_id, match) do
    case Repo.get(ImportGroup, group_id) do
      nil -> {:error, :not_found}
      %ImportGroup{status: "pending"} = group -> apply_change_match(group, match)
      %ImportGroup{} -> {:error, :not_pending}
    end
  end

  defp apply_change_match(group, match) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    match = stringify_match(match)

    update_member_candidates(group.id, match, now)

    group
    |> Ecto.Changeset.change(
      provider_type: match.provider_type,
      provider_id: match.provider_id,
      suggested_title: match.title,
      suggested_year: match.year,
      media_type: match.media_type,
      min_confidence: 1.0,
      evidence: %{"kind" => "manual", "candidates" => 1, "disagreement" => false},
      updated_at: now
    )
    |> Repo.update()
  end

  defp stringify_match(match) do
    %{
      provider_id: to_string(match.provider_id),
      provider_type: to_string(match.provider_type),
      title: match.title,
      year: match.year,
      media_type: to_string(match.media_type)
    }
  end

  # Chunked the same way stamp_members/2 is: the `id in ^ids` list this
  # builds for the WHERE clause is capped at @id_bind_chunk, so even a group
  # the size of galactica's largest (299 files) issues a handful of updates
  # rather than one query per member. `members(group_id, limit: 100_000)`
  # mirrors create_local_show/1's own choice for "walk every member of one
  # group" -- these unresolved files carry no analysis blobs yet (those are
  # written after a file links), so the blob-column cost `ImportGroups`'s own
  # moduledoc warns about elsewhere does not apply here.
  #
  # A member with no rank-0 candidate row at all (the ~1-in-1000 case the
  # design doc's own evidence section measured) is left untouched: it was
  # already unreachable by ApplyImportGroups.ingest_member/2's `candidate:
  # nil` clause before this ran, and correcting the group's match does not
  # change that.
  defp update_member_candidates(group_id, match, now) do
    group_id
    |> members(limit: 100_000)
    |> Enum.map(& &1.media_file.id)
    |> Enum.chunk_every(@id_bind_chunk)
    |> Enum.each(fn ids ->
      MatchCandidate
      |> where([c], c.media_file_id in ^ids and c.rank == 0)
      |> Repo.update_all(
        set: [
          provider_id: match.provider_id,
          provider_type: match.provider_type,
          title: match.title,
          year: match.year,
          media_type: match.media_type,
          confidence: 1.0,
          last_error: nil,
          attempts: 0,
          updated_at: now
        ]
      )
    end)
  end

  @doc """
  One group's member files, for lazy expansion in the UI.

  Capped by `:limit` (default 200). A group can hold tens of thousands of files
  and the page must never render them all.
  """
  @spec members(binary(), keyword()) :: [
          %{media_file: MediaFile.t(), candidate: MatchCandidate.t() | nil}
        ]
  def members(group_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    MediaFile
    |> where([f], f.import_group_id == ^group_id)
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at))
    |> join(:left, [f], c in MatchCandidate, on: c.media_file_id == f.id and c.rank == 0)
    |> order_by([f], asc: f.relative_path)
    |> limit(^limit)
    |> select([f, c], %{media_file: f, candidate: c})
    |> Repo.all()
  end

  @doc "How many unresolved members a group still has."
  @spec member_count(binary()) :: non_neg_integer()
  def member_count(group_id) do
    MediaFile
    |> where([f], f.import_group_id == ^group_id)
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Updates the assigned season and episode numbers for a group member file.

  Updates or creates the member's rank-0 `MatchCandidate` with the updated
  `parsed_info` and recalculates the parent group's `season_span` and
  `numbered_count`.
  """
  @spec update_member_episode(
          binary(),
          integer() | String.t() | nil,
          integer() | String.t() | nil
        ) ::
          {:ok, %{media_file: MediaFile.t(), candidate: MatchCandidate.t()}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def update_member_episode(media_file_id, season, episode) do
    with %MediaFile{} = file <- Repo.get(MediaFile, media_file_id) do
      parsed_season = parse_int(season)
      parsed_ep = parse_int(episode)
      episodes_list = if parsed_ep, do: [parsed_ep], else: []

      candidate = Repo.get_by(MatchCandidate, media_file_id: file.id, rank: 0)

      candidate_result =
        if candidate do
          parsed_info =
            (candidate.parsed_info || %{})
            |> Map.put("season", parsed_season)
            |> Map.put("episodes", episodes_list)

          candidate
          |> MatchCandidate.changeset(%{parsed_info: parsed_info})
          |> Repo.update()
        else
          group =
            if file.import_group_id, do: Repo.get(ImportGroup, file.import_group_id), else: nil

          parsed_info = %{
            "season" => parsed_season,
            "episodes" => episodes_list
          }

          %MatchCandidate{}
          |> MatchCandidate.changeset(%{
            media_file_id: file.id,
            rank: 0,
            title:
              (group && group.suggested_title) ||
                Path.rootname(Path.basename(file.relative_path || file.path || "")),
            year: group && group.suggested_year,
            provider_type: group && group.provider_type,
            provider_id: group && group.provider_id,
            media_type: (group && group.media_type) || "tv_show",
            confidence: (group && group.min_confidence) || 1.0,
            parsed_info: parsed_info
          })
          |> Repo.insert()
        end

      case candidate_result do
        {:ok, updated_candidate} ->
          if file.import_group_id do
            refresh_group_stats(file.import_group_id)
          end

          {:ok, %{media_file: file, candidate: updated_candidate}}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {val, ""} -> val
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp refresh_group_stats(group_id) do
    group = Repo.get(ImportGroup, group_id)

    if group do
      library_path = Settings.get_library_path!(group.library_path_id)

      members_data =
        MediaFile
        |> where([f], f.import_group_id == ^group_id)
        |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id) and is_nil(f.trashed_at))
        |> join(:left, [f], c in MatchCandidate, on: c.media_file_id == f.id and c.rank == 0)
        |> select([f, c], %{relative_path: f.relative_path, parsed_info: c.parsed_info})
        |> Repo.all()

      seasons =
        members_data
        |> Enum.reduce(MapSet.new(), fn row, acc ->
          case row.parsed_info do
            %{"season" => s} when is_integer(s) ->
              MapSet.put(acc, s)

            _ ->
              case PathAnchor.anchor_for(
                     Path.join(library_path.path, row.relative_path || ""),
                     library_path.path
                   ) do
                %{season_hint: s} when is_integer(s) -> MapSet.put(acc, s)
                _ -> acc
              end
          end
        end)
        |> MapSet.to_list()
        |> Enum.sort()

      numbered_count =
        Enum.count(members_data, fn row ->
          match?(%{"episodes" => [_ | _]}, row.parsed_info)
        end)

      group
      |> ImportGroup.changeset(%{
        season_span: seasons,
        numbered_count: numbered_count
      })
      |> Repo.update()
    end
  end

  @doc """
  Creates a local show from a group's folder name, for media no provider carries.

  Some libraries hold shows that TVDB and TMDB simply do not have. Without this
  those files can never leave the queue, however good the matcher gets, so an
  empty inbox would be unreachable.

  This does the linking itself rather than going through
  `Mydia.Jobs.ApplyImportGroups`, because that worker's whole job is to hand a
  provider match to `FileIngest`, and there is no provider match here. Episodes
  come from each file's parsed season and episode numbers instead.

  The show carries no provider identity: `MediaItem` has no `provider_type`
  column and its `metadata_source` is an `Ecto.Enum` limited to `[:tvdb, :tmdb]`,
  so a local show simply leaves `metadata_source`, `tmdb_id` and `tvdb_id` nil. A
  later re-match fills them in.

  `skip_episode_refresh: true` is passed to `Media.create_media_item/2`: its
  default behaviour for a `"tv_show"` is to fetch episodes from a metadata
  provider, which would spend a relay round-trip (and, in tests, an
  unstubbed HTTP call) trying to resolve a provider id that, by construction,
  does not exist for this show. Episodes come from the parsed file names
  instead, via `link_local_member/2` below.

  A member with no parsed episode number is left alone rather than guessed
  at: it stays an orphaned `MediaFile` (no `episode_id`, no `media_item_id`)
  and `unresolved_count` records how many. The group is marked `"applied"`
  only when every member linked. Otherwise it stays `"pending"`, so it keeps
  showing up on the review page, in the band counts, and in the nav badge --
  `write_group/4` deliberately preserves an existing group's status across a
  rescan, and this folder produces the same `cluster_key` every time, so a
  group (and its leftover file) marked "done" here would otherwise vanish for
  good the moment a human next looked for it. There is no provider match for
  a worker to retry against, so staying visible and human-actionable is what
  a partially-linked group gets instead of a retry.

  The group is stamped `provider_type: "local"` and a synthetic `provider_id`
  (`"local-" <> item.id`) so a second call against the same group -- a
  double-click (there is no `phx-disable-with` on the button), or a retry
  after a crash partway through the link loop -- is refused with
  `{:error, :already_created}` rather than building a second `MediaItem` and
  finding every member already detached from the first call. This has two
  knock-on effects:

    * The group leaves the `:no_match` band (see `band/1`): with
      `min_confidence` still nil it now lands in `:needs_attention`, so it
      stays visible on the unfiltered page and in the counts. It will not,
      however, appear under the `:needs_attention` *filter* specifically --
      a NULL `min_confidence` fails that band's SQL comparison in `page/2`.
      That asymmetry is accepted rather than fixed here.
    * `ApplyImportGroups.accepted_groups/1` excludes `provider_type: "local"`
      groups alongside its existing `provider_id` filter, so a group a human
      later accepts by hand can never hand `FileIngest` this synthetic id.
  """
  @spec create_local_show(binary()) :: {:ok, Media.MediaItem.t()} | {:error, term()}
  def create_local_show(group_id) do
    Repo.transaction(fn -> create_local_show_transaction(group_id) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_local_show_transaction(group_id) do
    group = Repo.get!(ImportGroup, group_id)

    cond do
      group.provider_type == "local" ->
        {:error, :already_created}

      group.provider_id ->
        {:error, :already_matched}

      true ->
        {title, year} = title_and_year(group)

        with {:ok, item} <-
               Media.create_media_item(
                 Scope.system(),
                 %{title: title, year: year, type: "tv_show", monitored: false},
                 skip_episode_refresh: true
               ) do
          group_id
          |> members(limit: 100_000)
          |> Enum.each(&link_local_member(&1, item))

          remaining = member_count(group_id)
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          group
          |> Ecto.Changeset.change(
            suggested_title: title,
            suggested_year: year,
            unresolved_count: remaining,
            status: if(remaining == 0, do: "applied", else: "pending"),
            provider_type: "local",
            provider_id: "local-" <> item.id,
            decided_at: now
          )
          |> Repo.update!()

          {:ok, item}
        end
    end
  end

  @doc """
  Creates local shows for selected groups from their folder names.

  Only processes pending groups with no provider_id and not already created as local.
  Returns `{:ok, %{created: count, skipped: count}}`.
  """
  @spec create_local_shows(SelectionScope.t()) ::
          {:ok, %{created: non_neg_integer(), skipped: non_neg_integer()}}
  def create_local_shows(%SelectionScope{} = scope) do
    groups =
      scope
      |> SelectionScope.to_query()
      |> where(
        [g],
        is_nil(g.provider_id) and (is_nil(g.provider_type) or g.provider_type != "local")
      )
      |> Repo.all()

    result =
      Enum.reduce(groups, %{created: 0, skipped: 0}, fn group, acc ->
        case safe_create_local_show(group.id) do
          {:ok, _item} -> %{acc | created: acc.created + 1}
          {:error, _reason} -> %{acc | skipped: acc.skipped + 1}
        end
      end)

    {:ok, result}
  end

  defp safe_create_local_show(group_id) do
    create_local_show(group_id)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  # Finds or creates the episode this file's parsed numbering points at, then
  # links the file to it. A file with no parsed episode number is left alone: it
  # stays in the group, which keeps `unresolved_count` honest and the group
  # visible rather than silently half-done.
  defp link_local_member(%{media_file: media_file, candidate: candidate}, item) do
    with %{} = parsed <- candidate && candidate.parsed_info,
         season when is_integer(season) <- Map.get(parsed, "season"),
         [number | _] <- Map.get(parsed, "episodes") || [] do
      episode =
        Repo.get_by(Episode,
          media_item_id: item.id,
          season_number: season,
          episode_number: number
        ) ||
          case Media.create_episode(%{
                 media_item_id: item.id,
                 season_number: season,
                 episode_number: number,
                 title: Path.rootname(Path.basename(media_file.relative_path))
               }) do
            {:ok, episode} -> episode
            {:error, _} -> nil
          end

      if episode do
        media_file
        |> Ecto.Changeset.change(episode_id: episode.id, import_group_id: nil)
        |> Repo.update()
      end
    else
      _ -> :ok
    end
  end

  # "Les mots de Passe-Partout (2023)" -> {"Les mots de Passe-Partout", 2023}
  defp title_and_year(%ImportGroup{display_title: display_title}) do
    case Regex.run(~r/^(.*?)\s*\((\d{4})\)\s*$/, display_title || "") do
      [_, title, year] -> {String.trim(title), String.to_integer(year)}
      _ -> {display_title, nil}
    end
  end

  # Insert an Oban job, falling back to a direct Repo insert when Oban's engine
  # is disabled (test mode). Mirrors the pattern in Search, Downloads.Queue, and
  # DownloadMonitor: config/test.exs sets `engine: false`, so the application
  # supervisor never starts an Oban process to insert against, and a bare
  # `Oban.insert/1` raises `RuntimeError` for every caller in the test suite.
  defp insert_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end
end
