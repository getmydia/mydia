defmodule Mydia.ImportCandidates.Deletion do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates.{Edits, Review, Store}
  alias Mydia.Library.{ImportCandidate, MediaFile, SelectionScope}
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  # --- Deleting from disk --------------------------------------------------

  @delete_page_size 250

  @doc """
  Queues every file in a selection for permanent deletion from disk.

  Same shape as `AcceptQueue.queue_accept/2` and `Rematch.queue_rematch/1`: one `UPDATE` stamps
  `queued_op: "delete"` and `Mydia.Jobs.DeleteImportCandidates` drains it, so
  the work outlives the page and the rows read as queued the moment the
  operator confirms.

  Two differences. The rows are narrowed to the status the operator is looking
  at (see `deletable_query/1`), and `dismissed_at` is cleared in the same
  statement, so a delete from the Ignored view keeps the rule that a queued row
  is never dismissed.

  Returns a file count, not a group count: the confirm dialog promised files.

  Pass `expected_files:` with the count the operator confirmed. When the
  selection no longer covers exactly that many files (a scan added some,
  another session queued or dismissed some), nothing is marked and this returns
  `{:error, {:count_changed, current}}`, so a delete never reaches files the
  operator did not see counted.
  """
  @spec queue_delete(SelectionScope.t(), keyword()) ::
          {:ok, %{files: non_neg_integer()}}
          | {:error, {:count_changed, non_neg_integer()}}
          | {:error, term()}
  def queue_delete(%SelectionScope{} = scope, opts \\ []) do
    scope
    |> deletable_query()
    |> mark_for_delete(scope.library_path_id, Keyword.get(opts, :expected_files))
  end

  @doc """
  Queues one candidate for permanent deletion from disk.

  Returns the candidate as it was before marking, or `{:error, :not_found}` when
  it is gone or already queued for anything, which a stale click from another
  tab produces routinely.
  """
  @spec queue_delete_candidate(binary()) ::
          {:ok, ImportCandidate.t()} | {:error, :not_found} | {:error, term()}
  def queue_delete_candidate(candidate_id) do
    case Repo.get(ImportCandidate, candidate_id) do
      %ImportCandidate{queued_op: nil} = candidate ->
        ImportCandidate
        |> where([c], c.id == ^candidate.id and is_nil(c.queued_op))
        |> mark_for_delete(candidate.library_path_id)
        |> case do
          {:ok, %{files: 1}} -> {:ok, candidate}
          {:ok, %{files: 0}} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc "How many files `queue_delete/1` would queue for `scope` right now."
  @spec count_files(SelectionScope.t()) :: non_neg_integer()
  def count_files(%SelectionScope{} = scope) do
    scope |> deletable_query() |> Repo.aggregate(:count)
  end

  # The rows a delete of `scope` takes: the selected anchors' candidates in the
  # status being viewed, and nothing already queued. `Edits.candidate_query/1` alone
  # selects every row in those anchors whatever its status, so without
  # `Review.filter_status/2` a delete from Ignored would also take a pending file a
  # later scan added to the same folder. `count_files/1` counts this same query,
  # so the confirm dialog and the delete cannot disagree.
  defp deletable_query(%SelectionScope{} = scope) do
    scope
    |> Edits.candidate_query()
    |> Review.filter_status(scope.status)
    |> where([c], is_nil(c.queued_op))
  end

  # The UPDATE and the job insert commit together. A job insert failing after
  # the rows were marked would leave them queued with nothing to drain them,
  # the same reason `Store.detach_to_review/4` enqueues inside its transaction.
  defp mark_for_delete(query, library_path_id, expected_files \\ nil) do
    now = Store.now()

    Repo.transaction(fn ->
      {files, _} =
        Repo.update_all(query,
          set: [
            queued_op: "delete",
            queued_at: now,
            queue_error: nil,
            dismissed_at: nil,
            updated_at: now
          ]
        )

      check_expected_files(files, expected_files)
      enqueue_delete_job(files, library_path_id)
      files
    end)
    |> case do
      {:ok, files} ->
        if files > 0, do: Store.broadcast(library_path_id)
        {:ok, %{files: files}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The count comes from the UPDATE itself, inside the transaction, so nothing
  # can join the selection between this check and the marking it rolls back.
  defp check_expected_files(_files, nil), do: :ok
  defp check_expected_files(files, files), do: :ok
  defp check_expected_files(files, _expected), do: Repo.rollback({:count_changed, files})

  # Nothing marked means nothing to drain, so no job. Called inside
  # `mark_for_delete/3`'s transaction, which `Repo.rollback/1` aborts.
  defp enqueue_delete_job(0, _library_path_id), do: :ok

  defp enqueue_delete_job(_files, library_path_id) do
    case Store.enqueue(Mydia.Jobs.DeleteImportCandidates, library_path_id) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Permanently deletes every file queued for delete on one library path, then
  its candidate row.

  Pages `queued_query(library_path_id, "delete")` in id order until nothing is
  left. Every row in a page leaves the queue: its row is deleted, or its marker
  is cleared with `queue_error` set, so the loop always makes progress and a
  file that cannot be removed is never retried forever. The operator sees the
  reason on the group instead.

  Each file is claimed before its bytes are touched. One transaction, under the
  same lock `Mydia.Library.CandidatePromotion` takes (SQLite's writer lock, the
  library path row on PostgreSQL), deletes the candidate row if it is still
  queued for delete and checks whether any library already owns the file. Only
  after that commits is the file unlinked. A promotion that got there first has
  already deleted the row or created the owning `media_files` row, and one that
  comes later finds its candidate missing and refuses, so an import can never
  promote a file this is about to delete.

  Ownership is decided by where the file is on disk, across every library path,
  not by the candidate's own `(library_path_id, relative_path)`. Library paths
  can nest, and a scan only asks whether its own library path owns a file, so
  an outer library can list an inner library's owned file as a candidate. A
  file some library owns, trashed or not, is never unlinked: its candidate row
  is dropped, the file stays, and it counts as `skipped`. Two library paths
  that reach the same directory through a symlink or a second mount are not
  recognised as the same place.

  A file that could not be removed gets its candidate row back, under its own
  id, with the reason in `queue_error`. If the worker dies after a claim commits
  and before the unlink, the request is lost but the file is not: it stays on
  disk and the next scan lists it again. Keeping a row through the unlink
  instead would leave it for a promotion to take, which is the race the claim
  exists to close.

  `:after_claim` is a zero-arity function run between the claim and the unlink,
  for tests that need to act inside that window.
  """
  @spec drain_delete(binary(), keyword()) ::
          {:ok,
           %{
             deleted: non_neg_integer(),
             failed: non_neg_integer(),
             skipped: non_neg_integer()
           }}
  def drain_delete(library_path_id, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @delete_page_size)

    result =
      drain_delete_pages(library_path_id, page_size, opts, %{deleted: 0, failed: 0, skipped: 0})

    Store.broadcast(library_path_id)
    result
  end

  defp drain_delete_pages(library_path_id, page_size, opts, acc) do
    rows =
      library_path_id
      |> Review.queued_query("delete")
      |> order_by([c], asc: c.id)
      |> limit(^page_size)
      |> preload(:library_path)
      |> Repo.all()

    if rows == [] do
      {:ok, acc}
    else
      acc = Enum.reduce(rows, acc, &delete_queued_candidate(&1, opts, &2))

      # One broadcast per page so the page watching this library drains visibly.
      Store.broadcast(library_path_id)

      drain_delete_pages(library_path_id, page_size, opts, acc)
    end
  end

  # Every outcome takes the row out of the queue (deleted, or its marker
  # cleared), which is what keeps `drain_delete_pages/4` from fetching it again.
  defp delete_queued_candidate(%ImportCandidate{} = candidate, opts, acc) do
    with path when is_binary(path) <- ImportCandidate.absolute_path(candidate) do
      claim_and_delete(candidate, Mydia.Library.Dirs.normalize(path), opts, acc)
    else
      nil ->
        record_delete_failure(candidate, :path_not_resolved)
        %{acc | failed: acc.failed + 1}
    end
  end

  defp claim_and_delete(candidate, path, opts, acc) do
    case claim_for_delete(candidate, path) do
      {:ok, :claimed} ->
        run_after_claim(opts)
        unlink_claimed(candidate, path, acc)

      # Owned by a library, or no longer queued for delete by the time the lock
      # was held (promoted, cleared, or reaped). Either way nothing is unlinked.
      {:ok, _owned_or_gone} ->
        %{acc | skipped: acc.skipped + 1}

      {:error, reason} ->
        record_delete_failure(candidate, reason)
        %{acc | failed: acc.failed + 1}
    end
  end

  defp claim_for_delete(%ImportCandidate{id: id, library_path_id: library_path_id}, path) do
    transaction_opts = if Mydia.DB.sqlite?(), do: [mode: :immediate], else: []

    Repo.transaction(
      fn ->
        lock_library_path(library_path_id)

        case ImportCandidate
             |> where([c], c.id == ^id and c.queued_op == "delete")
             |> Repo.delete_all() do
          {0, _} -> :gone
          {_claimed, _} -> if library_owns_file?(path), do: :owned, else: :claimed
        end
      end,
      transaction_opts
    )
  end

  # The same serialization `CandidatePromotion.lock_group/1` starts with:
  # PostgreSQL takes the library path row, SQLite already holds its single
  # writer lock from `mode: :immediate`.
  defp lock_library_path(library_path_id) do
    if Mydia.DB.postgres?() do
      LibraryPath
      |> where([lp], lp.id == ^library_path_id)
      |> lock("FOR UPDATE")
      |> select([lp], lp.id)
      |> Repo.one()
    end
  end

  defp library_owns_file?(path) do
    LibraryPath
    |> select([lp], {lp.id, lp.path})
    |> Repo.all()
    |> Enum.flat_map(&path_under_root(path, &1))
    |> Enum.any?(fn {library_path_id, relative_path} ->
      MediaFile
      |> where([f], f.library_path_id == ^library_path_id and f.relative_path == ^relative_path)
      |> Repo.exists?()
    end)
  end

  defp path_under_root(path, {library_path_id, root}) when is_binary(root) do
    prefix = (root |> Mydia.Library.Dirs.normalize() |> String.trim_trailing("/")) <> "/"

    if String.starts_with?(path, prefix),
      do: [{library_path_id, String.replace_prefix(path, prefix, "")}],
      else: []
  end

  defp path_under_root(_path, _library_path), do: []

  defp run_after_claim(opts) do
    case Keyword.get(opts, :after_claim) do
      callback when is_function(callback, 0) -> callback.()
      _ -> :ok
    end
  end

  defp unlink_claimed(candidate, path, acc) do
    case Mydia.Library.delete_path_from_disk(path) do
      :ok ->
        %{acc | deleted: acc.deleted + 1}

      {:error, %Mydia.Storage.Error{} = error} ->
        restore_failed_candidate(candidate, {:storage, error})
        %{acc | failed: acc.failed + 1}

      {:error, reason} ->
        restore_failed_candidate(candidate, reason)
        %{acc | failed: acc.failed + 1}
    end
  end

  # The claim deleted the row, so a file that could not be removed puts it back
  # with the reason, under its own id so an open member list keeps its place.
  # A scan can have rediscovered the path in the meantime; the conflict clause
  # writes the reason onto that row instead.
  defp restore_failed_candidate(%ImportCandidate{} = candidate, reason) do
    now = Store.now()

    row =
      struct(ImportCandidate, %{
        Map.take(candidate, ImportCandidate.__schema__(:fields))
        | queued_op: nil,
          queued_at: nil,
          queue_error: delete_error_message(reason),
          updated_at: now
      })

    case Repo.insert(row,
           on_conflict: {:replace, [:queued_op, :queued_at, :queue_error, :updated_at]},
           conflict_target: [:library_path_id, :relative_path]
         ) do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.error("Could not restore an import candidate whose file failed to delete",
          candidate_id: candidate.id,
          relative_path: candidate.relative_path,
          errors: inspect(changeset.errors)
        )
    end
  end

  # Conditional on the op, like `Rematch.clear_rematch_markers/1`: only a row still
  # queued for delete has the failure written onto it.
  defp record_delete_failure(%ImportCandidate{id: id}, reason) do
    now = Store.now()

    ImportCandidate
    |> where([c], c.id == ^id and c.queued_op == "delete")
    |> Repo.update_all(
      set: [
        queued_op: nil,
        queued_at: nil,
        queue_error: delete_error_message(reason),
        updated_at: now
      ]
    )
  end

  defp delete_error_message(:path_not_resolved),
    do: "Could not delete from disk: the library path could not be resolved."

  defp delete_error_message({:storage, %Mydia.Storage.Error{message: message}}),
    do: "Could not delete: #{message}."

  defp delete_error_message(reason) when is_atom(reason),
    do: "Could not delete from disk: #{:file.format_error(reason)}."

  defp delete_error_message(reason), do: "Could not delete from disk: #{inspect(reason)}."
end
