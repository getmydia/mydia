defmodule Mydia.ImportCandidates.AcceptQueue do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates.{Edits, Review, Store}
  alias Mydia.Library.{CandidatePromotion, ImportCandidate, ImportCandidateGroup, SelectionScope}
  alias Mydia.Repo

  @queue_anchor_page_size 25

  # Refusals that will fail identically on every retry, so the marker is cleared
  # and the reason surfaced instead of burning the retry budget.
  @terminal_accept_errors [:no_match, :conflicting_providers, :local_show, :empty_group]

  @doc """
  Queues a selection for import.

  One `UPDATE ... WHERE` marks every eligible candidate in the selected anchors,
  then one Oban job is enqueued for the library path. A `:filter`-mode selection
  carries no ids, so this stays a single statement no matter how many groups it
  covers, and the snapshot is taken against what the user was looking at rather
  than re-derived when the job eventually runs.

  Eligibility is applied here rather than in the worker. A group with no
  provider match, or with files matching different titles, or carrying the
  synthetic `"local"` provider can never be promoted, so letting it move into
  Queued and bounce straight back with an error would be churn on the most
  common bulk path.

  `exclude_returned: true` also skips groups holding a candidate an operator
  returned to review. Only `queue_accept_all_matched/1` passes it: an explicit
  selection is a person looking at the group, which is what a returned file
  is waiting for.
  """
  @spec queue_accept(SelectionScope.t(), keyword()) ::
          {:ok, %{queued: non_neg_integer(), skipped: non_neg_integer()}}
  def queue_accept(%SelectionScope{} = scope, opts \\ []) do
    now = Store.now()
    eligible = eligible_accept_keys(scope, opts)

    # Both counts have to be read before the UPDATE. Marking a row sets
    # `queued_op`, which `Review.filter_status/2` excludes from "pending", so the same
    # two queries run afterwards would count only what was left behind.
    queued = eligible |> subquery() |> Repo.aggregate(:count)
    selected = Edits.selected_group_count(scope)

    {row_count, _} =
      ImportCandidate
      |> where([c], c.library_path_id == ^scope.library_path_id)
      |> where([c], c.anchor_key in subquery(eligible))
      |> where([c], is_nil(c.dismissed_at) and is_nil(c.queued_op))
      |> Repo.update_all(
        set: [queued_op: "accept", queued_at: now, queue_error: nil, updated_at: now]
      )

    if row_count > 0 do
      Store.enqueue(Mydia.Jobs.ApplyImportCandidates, scope.library_path_id)
      Store.broadcast(scope.library_path_id)
    end

    # `queued`/`selected` are read before the UPDATE (see above) and so, on a
    # `"queued"`-status scope, still count groups whose candidates already
    # carry a `queued_op` -- the UPDATE's own `is_nil(c.queued_op)` guard then
    # matches zero rows for them. Gating the return on `row_count` (as
    # `Edits.dismiss/1` and `Rematch.queue_rematch/1` already do) keeps this from reporting
    # a queue that did not happen.
    {queued, skipped} = if row_count > 0, do: {queued, selected - queued}, else: {0, selected}

    {:ok, %{queued: queued, skipped: skipped}}
  end

  @doc """
  Queues every pending provider-matched group for one library path.

  Confidence is deliberately not filtered: this is the explicit human override
  behind the review page's "Import all" control. Groups holding a returned
  candidate are skipped, because a returned file's suggestion can name the very
  item it was sent back from, and this control accepts without showing it.
  """
  @spec queue_accept_all_matched(binary()) ::
          {:ok, %{queued: non_neg_integer(), skipped: non_neg_integer()}}
  def queue_accept_all_matched(library_path_id) do
    library_path_id
    |> SelectionScope.new()
    |> SelectionScope.select_all_matching(%{})
    |> queue_accept(exclude_returned: true)
  end

  # The selected anchors that `accept_group/2` would actually accept, as a
  # grouped subquery of anchor keys. `count(provider_id, :distinct) == 1`
  # subsumes the no-match case as well: SQL counts of a nullable column ignore
  # NULLs, so a group with no provider match counts zero.
  defp eligible_accept_keys(%SelectionScope{} = scope, opts) do
    scope
    |> SelectionScope.to_query()
    |> exclude(:select)
    |> having([c], count(c.provider_id, :distinct) == 1)
    |> having([c], is_nil(max(c.provider_type)) or max(c.provider_type) != "local")
    |> maybe_exclude_returned(Keyword.get(opts, :exclude_returned, false))
    |> select([c], c.anchor_key)
  end

  defp maybe_exclude_returned(query, true), do: having(query, [c], count(c.returned_at) == 0)
  defp maybe_exclude_returned(query, false), do: query

  defp accept_group(%ImportCandidateGroup{provider_id: nil}, _opts), do: {:error, :no_match}

  defp accept_group(%ImportCandidateGroup{provider_count: provider_count}, _opts)
       when provider_count != 1,
       do: {:error, :conflicting_providers}

  defp accept_group(%ImportCandidateGroup{provider_type: "local"}, _opts),
    do: {:error, :local_show}

  defp accept_group(%ImportCandidateGroup{library_path_id: lp_id, anchor_key: key}, opts) do
    case load_queued_members(lp_id, key, "accept") do
      [] ->
        {:error, :empty_group}

      candidates ->
        match = candidates |> List.first() |> ImportCandidate.to_match()
        CandidatePromotion.promote_group(candidates, match, opts)
    end
  end

  # Only the rows queued for `op`. A mixed anchor (rows queued for `op` plus
  # either a pending newcomer a concurrent scan inserted, or rows queued for a
  # different op) must promote exactly its own op's subset, which is the set
  # `Review.queued_group/3` computed the group's eligibility from. Everything else
  # stays put and shows up under its own status on the next pass.
  #
  # Filtering in memory rather than in SQL is deliberate: `Review.load_all_members/2`
  # already pages the anchor in bounded chunks and hands back the full
  # membership, and a mixed anchor holds at most a handful of rows outside
  # `op`.
  defp load_queued_members(library_path_id, anchor_key, op) do
    library_path_id
    |> Review.load_all_members(anchor_key)
    |> Enum.filter(&(&1.queued_op == op))
  end

  # The pending (queued_op IS NULL) subset of one anchor's membership -- the
  # counterpart to `load_queued_members/3` for callers that act on whatever
  # has not already been claimed by a queued op. `LocalShows.create_local_show/2`
  # uses this rather than `Review.load_all_members/2`: a scan can insert a pending row
  # under an anchor whose import is already queued (see the moduledoc on that
  # theme), and a queued row's provider identity and eventual promotion must
  # not be disturbed by an unrelated "create local show from folder" call
  # against the same anchor.
  @doc false
  def load_pending_members(library_path_id, anchor_key) do
    library_path_id
    |> Review.load_all_members(anchor_key)
    |> Enum.filter(&is_nil(&1.queued_op))
  end

  @doc """
  Promotes every group queued for accept on one library path.

  Discovers its own work from `queued_op`, so a restarted job resumes where it
  stopped and a second accept queued while this runs is picked up by the same
  loop. Groups are drained in anchor pages, but every currently-queued anchor
  is swept once (in keyset-paged pages of `:anchor_page_size`) before this
  decides whether the pass made progress -- an early anchor that fails
  without clearing its marker cannot strand anchors ordered after it, only
  slow down how many full sweeps a stuck queue costs. The whole membership of
  one group still goes to `CandidatePromotion.promote_group/3` in a single
  call, which is the only transaction boundary here.

  A terminal refusal (no provider match, files matching different titles, a
  synthetic local show, a group whose rows vanished) clears the marker and
  records `queue_error`, returning the group to the pending list with an
  explanation rather than leaving it queued forever. Anything else leaves the
  marker in place, so `remaining` is non-zero and the worker reports failure for
  Oban to retry.
  """
  @spec drain_accepted(binary(), keyword()) ::
          {:ok,
           %{
             promoted: non_neg_integer(),
             failed: non_neg_integer(),
             remaining: non_neg_integer()
           }}
  def drain_accepted(library_path_id, opts \\ []) do
    page_size = Keyword.get(opts, :anchor_page_size, @queue_anchor_page_size)

    result =
      drain_accepted_pages(
        library_path_id,
        opts,
        page_size,
        queued_count(library_path_id, "accept"),
        %{promoted: 0, failed: 0}
      )

    Store.broadcast(library_path_id)
    result
  end

  # A "no progress" stop has to be decided across one *complete* sweep of
  # every currently-queued anchor, not one anchor page: `queued_anchor_keys/4`
  # is keyset-paged, and an early page that makes zero progress must not
  # short-circuit the anchors past it. Deciding per-page (as this used to)
  # left later-ordered anchors permanently stranded behind a page-size-or-more
  # run of identically-failing early ones, across every one of Oban's
  # retries -- see the finding this fixed. `sweep_accepted/5` walks the whole
  # queued set once, advancing its cursor past every anchor it touches
  # regardless of outcome; only once that full walk completes does this
  # compare `remaining` against `remaining_before` to decide whether another
  # sweep is worth attempting or the loop should stop and let the worker's
  # retry (or a stuck anchor's terminal clear) take over.
  defp drain_accepted_pages(library_path_id, opts, page_size, remaining_before, acc) do
    acc = sweep_accepted(library_path_id, opts, page_size, nil, acc)
    remaining = queued_count(library_path_id, "accept")

    cond do
      remaining == 0 ->
        {:ok, Map.put(acc, :remaining, 0)}

      remaining < remaining_before ->
        drain_accepted_pages(library_path_id, opts, page_size, remaining, acc)

      # No progress across a whole sweep: every still-queued anchor failed
      # without clearing its marker, so another sweep would fetch the same
      # anchors and fail identically. Stop and let the worker's retry handle
      # it.
      true ->
        {:ok, Map.put(acc, :remaining, remaining)}
    end
  end

  # One full keyset walk over every anchor currently queued for accept,
  # advancing `after_key` past each page regardless of whether its anchors
  # promoted or failed -- unlike re-fetching from the same cursor, a failure
  # can never cause this to refetch (and re-attempt) the anchor(s) that just
  # failed, so no later-ordered anchor is ever left unreached by a stuck
  # earlier one.
  defp sweep_accepted(library_path_id, opts, page_size, after_key, acc) do
    keys = queued_anchor_keys(library_path_id, "accept", page_size, after_key)

    if keys == [] do
      acc
    else
      acc = Enum.reduce(keys, acc, &promote_queued_anchor(library_path_id, &1, opts, &2))

      # One broadcast per page, not per group: the review page's Queued chip
      # drains visibly while the job runs, and the LiveView's own burst debounce
      # keeps that from becoming a re-render storm.
      Store.broadcast(library_path_id)

      sweep_accepted(library_path_id, opts, page_size, List.last(keys), acc)
    end
  end

  defp promote_queued_anchor(library_path_id, anchor_key, opts, acc) do
    case Review.queued_group(library_path_id, anchor_key, "accept") do
      nil ->
        # The rows went away mid-drain, which LocalShows.clear_for_library/1 and
        # Store.delete_missing/3 can both do. There is nothing left to promote, so
        # this is not a retryable failure.
        %{acc | failed: acc.failed + 1}

      group ->
        promote_queued_group(library_path_id, anchor_key, group, opts, acc)
    end
  end

  defp promote_queued_group(library_path_id, anchor_key, group, opts, acc) do
    case accept_group(group, opts) do
      {:ok, _media_files} ->
        %{acc | promoted: acc.promoted + 1}

      {:error, reason} when reason in @terminal_accept_errors ->
        clear_queue_marker(library_path_id, anchor_key, "accept", queue_error_message(reason))
        %{acc | failed: acc.failed + 1}

      {:error, reason} ->
        Logger.warning("A queued import group did not promote, leaving it queued for retry",
          library_path_id: library_path_id,
          anchor_key: anchor_key,
          reason: inspect(reason)
        )

        %{acc | failed: acc.failed + 1}
    end
  rescue
    error ->
      Logger.error("Promoting a queued import group raised, leaving it queued for retry",
        library_path_id: library_path_id,
        anchor_key: anchor_key,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      %{acc | failed: acc.failed + 1}
  end

  defp queued_anchor_keys(library_path_id, op, limit, after_key) do
    library_path_id
    |> Review.queued_query(op)
    |> maybe_after_anchor_key(after_key)
    |> distinct(true)
    |> order_by([c], asc: c.anchor_key)
    |> select([c], c.anchor_key)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_after_anchor_key(query, nil), do: query
  defp maybe_after_anchor_key(query, key), do: where(query, [c], c.anchor_key > ^key)

  defp queued_count(library_path_id, op) do
    library_path_id
    |> Review.queued_query(op)
    |> Repo.aggregate(:count)
  end

  defp clear_queue_marker(library_path_id, anchor_key, op, error) do
    now = Store.now()

    library_path_id
    |> Review.queued_query(op)
    |> where([c], c.anchor_key == ^anchor_key)
    |> Repo.update_all(set: [queued_op: nil, queued_at: nil, queue_error: error, updated_at: now])
  end

  defp queue_error_message(:no_match), do: "No provider match to import from."

  defp queue_error_message(:conflicting_providers),
    do: "Files in this folder match different titles."

  defp queue_error_message(:local_show), do: "Local shows are created directly, not imported."
  defp queue_error_message(:empty_group), do: "No files left to import."
end
