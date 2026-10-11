defmodule Mydia.ImportCandidates.Rematch do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates.{Edits, Review, Store}
  alias Mydia.Library.{BatchMatcher, FileIngest, ImportCandidate, SelectionScope}
  alias Mydia.Metadata
  alias Mydia.Repo
  alias Mydia.Settings

  @rematch_page_size 250

  @doc """
  Queues a selection for re-matching.

  Same shape as `AcceptQueue.queue_accept/2` with no eligibility filter, since
  any candidate can be re-matched.
  """
  @spec queue_rematch(SelectionScope.t()) :: {:ok, %{queued: non_neg_integer()}}
  def queue_rematch(%SelectionScope{} = scope) do
    now = Store.now()
    group_count = Edits.selected_group_count(scope)

    {row_count, _} =
      scope
      |> Edits.candidate_query()
      |> where([c], is_nil(c.dismissed_at) and is_nil(c.queued_op))
      |> Repo.update_all(
        set: [queued_op: "rematch", queued_at: now, queue_error: nil, updated_at: now]
      )

    if row_count > 0 do
      Store.enqueue(Mydia.Jobs.RematchImportCandidates, scope.library_path_id)
      Store.broadcast(scope.library_path_id)
    end

    {:ok, %{queued: if(row_count > 0, do: group_count, else: 0)}}
  end

  @doc """
  Re-runs metadata matching for every candidate queued for re-match on one
  library path.

  Matches through `Mydia.Library.BatchMatcher` in bounded pages and writes each
  result back with `Mydia.Library.FileIngest.ingest/3` under the `:review`
  policy, which records the verdict and never auto-promotes. Every row in a page
  has its marker cleared once the page is ingested, whether it matched or not, so
  the loop always makes progress and a re-match is never retried forever over a
  file no provider recognises.
  """
  @spec drain_rematch(binary(), keyword()) ::
          {:ok,
           %{files: non_neg_integer(), failures: non_neg_integer(), remaining: non_neg_integer()}}
  def drain_rematch(library_path_id, opts \\ []) do
    library_path = Settings.get_library_path!(library_path_id)
    matcher = Keyword.get(opts, :matcher, Mydia.Library.MetadataMatcher)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    page_size = Keyword.get(opts, :page_size, @rematch_page_size)

    result =
      drain_rematch_pages(library_path, matcher, config, page_size, %{files: 0, failures: 0})

    Store.broadcast(library_path_id)
    result
  end

  defp drain_rematch_pages(library_path, matcher, config, page_size, acc) do
    rows =
      library_path.id
      |> Review.queued_query("rematch")
      |> order_by([c], asc: c.id)
      |> limit(^page_size)
      |> Repo.all()

    if rows == [] do
      {:ok, Map.put(acc, :remaining, 0)}
    else
      page_stats = rematch_rows(rows, library_path, matcher, config)
      clear_rematch_markers(Enum.map(rows, & &1.id))

      # One broadcast per page so the Queued chip drains visibly.
      Store.broadcast(library_path.id)

      acc = Map.merge(acc, page_stats, fn _key, left, right -> left + right end)
      drain_rematch_pages(library_path, matcher, config, page_size, acc)
    end
  end

  # Conditional on the op, so a row the user has since queued for accept keeps
  # its new marker instead of being cleared by an in-flight re-match.
  defp clear_rematch_markers(ids) do
    now = Store.now()

    ImportCandidate
    |> where([c], c.id in ^ids and c.queued_op == "rematch")
    |> Repo.update_all(set: [queued_op: nil, queued_at: nil, updated_at: now])
  end

  defp rematch_rows(rows, library_path, matcher, config) do
    rows_by_path = Map.new(rows, &{Path.join(library_path.path, &1.relative_path), &1})

    rows_by_path
    |> Map.keys()
    |> BatchMatcher.match_paths(library_root: library_path.path, matcher: matcher, config: config)
    |> Enum.reduce(%{files: 0, failures: 0}, fn {path, outcome}, stats ->
      case rematch_candidate(rows_by_path[path], outcome) do
        :ok -> %{stats | files: stats.files + 1}
        :error -> %{stats | failures: stats.failures + 1}
      end
    end)
  end

  defp rematch_candidate(candidate, outcome) do
    case outcome do
      {:ok, match} ->
        ingest_stat(FileIngest.ingest(candidate, match, policy: :review))

      {:error, reason} when reason in [:no_match, :no_matches_found, :unknown_media_type] ->
        ingest_stat(FileIngest.ingest(candidate, nil, policy: :review))

      {:error, _reason} ->
        :error
    end
  rescue
    error ->
      Logger.error("Re-matching an import candidate failed",
        candidate_id: candidate.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  end

  defp ingest_stat({:error, _reason}), do: :error
  defp ingest_stat(_result), do: :ok
end
