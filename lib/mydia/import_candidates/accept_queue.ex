defmodule Mydia.ImportCandidates.AcceptQueue do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates.{Edits, Review, Store}
  alias Mydia.Metadata.Provider.Error, as: ProviderError
  alias Mydia.Library.{CandidatePromotion, ImportCandidate, ImportCandidateGroup, SelectionScope}
  alias Mydia.Repo

  @queue_anchor_page_size 25

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

  @doc """
  Returns a selection's accept-queued groups to review.

  Only `"accept"` markers are cleared. A re-match always drains itself, and a
  queued delete may already be removing files, so neither is cancellable here.
  A group the drain is promoting at that moment still finishes: promotion
  does not re-check `queued_op`, and the user did ask for the import.

  `returned` counts the distinct groups that held an accept marker, not the
  selected groups, so a selection mixing in rematch or delete groups does not
  overstate it.
  """
  @spec cancel_accept(SelectionScope.t()) :: {:ok, %{returned: non_neg_integer()}}
  def cancel_accept(%SelectionScope{} = scope) do
    now = Store.now()

    accept_queued =
      scope
      |> Edits.candidate_query()
      |> where([c], c.queued_op == "accept")

    returned =
      accept_queued
      |> select([c], count(c.anchor_key, :distinct))
      |> Repo.one()

    {row_count, _} =
      Repo.update_all(accept_queued,
        set: [queued_op: nil, queued_at: nil, queue_error: nil, updated_at: now]
      )

    if row_count > 0, do: Store.broadcast(scope.library_path_id)

    {:ok, %{returned: if(row_count > 0, do: returned, else: 0)}}
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
  synthetic local show, a group whose rows vanished, a path already in the
  library, an unresolvable episode, a movie/show mismatch, an unusable provider
  ID, a title the provider no longer has) clears the marker and
  records `queue_error`, returning the group to the pending list with an
  explanation rather than leaving it queued forever. Anything else leaves the
  marker in place, so `remaining` is non-zero and the worker reports failure for
  Oban to retry.

  With `final_attempt: true` (the worker's last Oban attempt) a drain that
  still has groups queued after its sweeps clears every remaining marker,
  recording the reason each failed group last failed for in `queue_error`, and
  returns the count still queued (rows marked mid-drain, which belong to the
  job that queued them). Nothing drains a marker after the last attempt, so
  leaving it set would strand the group in Queued forever.
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
        %{promoted: 0, failed: 0, reasons: %{}}
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
        {:ok, drain_result(acc, 0)}

      remaining < remaining_before ->
        drain_accepted_pages(library_path_id, opts, page_size, remaining, acc)

      # No progress across a whole sweep: every still-queued anchor failed
      # without clearing its marker, so another sweep would fetch the same
      # anchors and fail identically. Stop and let the worker's retry handle
      # it.
      Keyword.get(opts, :final_attempt, false) ->
        give_up_queued(library_path_id, acc.reasons)
        {:ok, drain_result(acc, queued_count(library_path_id, "accept"))}

      true ->
        {:ok, drain_result(acc, remaining)}
    end
  end

  # `reasons` is bookkeeping for `give_up_queued/2`, not part of the public
  # result shape.
  defp drain_result(acc, remaining),
    do: acc |> Map.delete(:reasons) |> Map.put(:remaining, remaining)

  # The job's last attempt. Nothing will drain these markers after this
  # returns, so every anchor this drain saw fail is cleared with the reason it
  # failed for, and the group goes back to review instead of sitting in Queued
  # forever (#1212). Only anchors with a recorded failure: a row a concurrent
  # `queue_accept` marked after the sweep passed its anchor belongs to the
  # fresh job that call enqueued (`unique` excludes :executing), and rejecting
  # it here would be a spurious failure for an accept nothing has tried yet.
  #
  # Public (`@doc false`) only so a test can seed that concurrent row, which
  # cannot be arranged through the sweep.
  @doc false
  def give_up_queued(library_path_id, reasons) do
    Logger.warning("Import retries exhausted, returning queued groups to review",
      library_path_id: library_path_id,
      anchor_count: map_size(reasons)
    )

    # `reasons` maps anchor_key => {reason, attempted_at}. Only rows queued at or
    # before `attempted_at` are cleared: a later `queued_at` means the operator
    # cancelled and re-accepted the group mid-drain and a fresh job owns it.
    # `queued_at` has second precision, so a re-accept within the same second as
    # the failed attempt's rows is still cleared; that is an accepted limitation.
    # A nil `attempted_at` (rows gone, or the lookup failed) clears unfiltered, so
    # a failed lookup can never strand a row.
    for {anchor_key, {reason, attempted_at}} <- reasons do
      clear_queue_marker(
        library_path_id,
        anchor_key,
        "accept",
        retry_exhausted_message(reason),
        attempted_at
      )
    end

    :ok
  end

  @retry_exhausted_fallback "Import failed after several attempts. Check the server logs."

  # Formatting must never skip the clear: a raise here on the last attempt
  # would strand the row, which is the bug this exists to prevent.
  defp retry_exhausted_message(reason) do
    "Import failed after several attempts: " <>
      (reason |> short_reason() |> String.slice(0, 120))
  rescue
    _ -> @retry_exhausted_fallback
  end

  defp short_reason({:metadata_fetch_failed, %ProviderError{message: message}})
       when is_binary(message),
       do: message

  defp short_reason({:storage, %Mydia.Storage.Error{kind: kind}}), do: "storage #{kind}"
  defp short_reason({:raised, %{__exception__: true} = error}), do: Exception.message(error)
  defp short_reason(reason), do: inspect(reason)

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

      {:error, reason} ->
        if terminal_accept_error?(reason) do
          clear_queue_marker(library_path_id, anchor_key, "accept", queue_error_message(reason))
          %{acc | failed: acc.failed + 1}
        else
          Logger.warning("A queued import group did not promote, leaving it queued for retry",
            library_path_id: library_path_id,
            anchor_key: anchor_key,
            reason: inspect(reason)
          )

          record_failure(acc, library_path_id, anchor_key, reason)
        end
    end
  rescue
    error ->
      Logger.error("Promoting a queued import group raised, leaving it queued for retry",
        library_path_id: library_path_id,
        anchor_key: anchor_key,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      record_failure(acc, library_path_id, anchor_key, {:raised, error})
  end

  # Stores the reason with the newest `queued_at` among the anchor's accept rows
  # now, so the final-attempt give-up can tell this attempt's rows from a
  # re-accept that lands later.
  defp record_failure(acc, library_path_id, anchor_key, reason) do
    attempted_at =
      try do
        library_path_id
        |> Review.queued_query("accept")
        |> where([c], c.anchor_key == ^anchor_key)
        |> select([c], max(c.queued_at))
        |> Repo.one()
      rescue
        _ -> nil
      end

    %{
      acc
      | failed: acc.failed + 1,
        reasons: Map.put(acc.reasons, anchor_key, {reason, attempted_at})
    }
  end

  # Refusals that fail identically on every retry, so the marker is cleared and
  # the reason surfaced instead of burning the retry budget. Anything not named
  # here (storage or relay outages, a candidate edited mid-drain, a raise) is
  # left queued for Oban to retry. See #1212 for what happens when a
  # deterministic refusal is missing from this list.
  defp terminal_accept_error?(reason)
       when reason in [
              :no_match,
              :conflicting_providers,
              :local_show,
              :empty_group,
              :unresolved_episode,
              :mixed_group
            ],
       do: true

  defp terminal_accept_error?({:duplicate_path, _, _}), do: true
  defp terminal_accept_error?({:incompatible_media_type, _, _}), do: true
  defp terminal_accept_error?({:invalid_provider_id, _}), do: true
  defp terminal_accept_error?({:invalid_match_result, _}), do: true

  defp terminal_accept_error?({:metadata_fetch_failed, %ProviderError{type: :not_found}}),
    do: true

  # A validation failure on the file insert (a movie into a series-only library
  # path, say) repeats identically on every retry.
  defp terminal_accept_error?(%Ecto.Changeset{}), do: true

  defp terminal_accept_error?(_reason), do: false

  defp queued_anchor_keys(library_path_id, op, limit, after_key) do
    library_path_id
    |> Review.queued_query(op)
    |> maybe_after_anchor_key(after_key)
    |> distinct(true)
    |> order_by([c], asc: c.anchor_key)
    |> select([c], c.anchor_key)
    |> maybe_limit(limit)
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_after_anchor_key(query, nil), do: query
  defp maybe_after_anchor_key(query, key), do: where(query, [c], c.anchor_key > ^key)

  defp queued_count(library_path_id, op) do
    library_path_id
    |> Review.queued_query(op)
    |> Repo.aggregate(:count)
  end

  defp clear_queue_marker(library_path_id, anchor_key, op, error, queued_at_max \\ nil) do
    now = Store.now()

    library_path_id
    |> Review.queued_query(op)
    |> where([c], c.anchor_key == ^anchor_key)
    |> maybe_queued_at_max(queued_at_max)
    |> Repo.update_all(set: [queued_op: nil, queued_at: nil, queue_error: error, updated_at: now])
  end

  defp maybe_queued_at_max(query, nil), do: query
  defp maybe_queued_at_max(query, max), do: where(query, [c], c.queued_at <= ^max)

  defp queue_error_message(:no_match), do: "No provider match to import from."

  defp queue_error_message(:conflicting_providers),
    do: "Files in this folder match different titles."

  defp queue_error_message(:local_show), do: "Local shows are created directly, not imported."
  defp queue_error_message(:empty_group), do: "No files left to import."

  defp queue_error_message({:duplicate_path, _, _}),
    do: "A file at this path is already in the library."

  defp queue_error_message(:unresolved_episode),
    do:
      "Couldn't tell which episode this file is. Multi-episode files and files " <>
        "without a season and episode number can't be imported yet."

  defp queue_error_message({:incompatible_media_type, _, _}),
    do: "This file's type doesn't match the matched title (movie or show)."

  defp queue_error_message(:mixed_group), do: "Files in this group belong to different folders."

  defp queue_error_message({reason, _})
       when reason in [:invalid_provider_id, :invalid_match_result],
       do: "The match is missing a usable provider ID. Re-match this group."

  # Only reached for the not_found case: callers format terminal reasons only.
  defp queue_error_message({:metadata_fetch_failed, _}),
    do: "The matched title no longer exists at the provider. Re-match this group."

  defp queue_error_message(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(messages, &changeset_error_line(field, &1))
      end)
      |> Enum.join("; ")

    String.slice("This file can't be added to the library: " <> details, 0, 200)
  end

  # Foreign keys and :base are internal; their messages read as full sentences.
  # Other fields get a prefix so "can't be blank" says what is blank.
  defp changeset_error_line(field, message) do
    if field == :base or String.ends_with?(to_string(field), "_id"),
      do: message,
      else: "#{field} #{message}"
  end
end
