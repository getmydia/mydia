defmodule Mydia.Jobs.PathMappingSuggestionBackfill do
  @moduledoc """
  One-shot worker that computes the stored path-mapping suggestion for
  downloads that failed with `path_mapping_mismatch` before suggestions were
  stored (#1315). New failures get theirs from `Mydia.Jobs.MediaImport.Failure`.

  Selection is by row state, so the worker is idempotent: it takes mismatch
  rows whose `path_mapping_searched_at` is nil, and every outcome stamps it,
  including a search that found nothing. The stamp is a conditional write, so a
  row that changed during the search is left alone.

  Runs on `:maintenance` so a slow mount search can never delay an import.
  The uniqueness setup and the self-reschedule follow `Mydia.Jobs.HdrBackfill`;
  its comments explain both.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Downloads.Download
  alias Mydia.Library.PathMapping
  alias Mydia.Repo

  @default_batch_size 25

  # See Mydia.Jobs.HdrBackfill: the reschedule must drop :executing or it
  # matches this job's own row and is silently never inserted.
  @reschedule_unique_states [:suspended, :available, :scheduled, :retryable]

  @doc """
  Enqueues the backfill. Called once at boot. Never raises, for the reason
  given on `Mydia.Jobs.HdrBackfill.enqueue_once/0`.
  """
  @spec enqueue_once() :: :ok
  def enqueue_once do
    %{} |> new() |> Oban.insert()
    :ok
  rescue
    error ->
      Logger.warning("Path-mapping suggestion backfill: failed to enqueue on boot",
        error: inspect(error)
      )

      :ok
  end

  @doc "Ids of mismatch downloads never searched for a suggestion, capped at `limit`."
  @spec pending_ids(pos_integer()) :: [binary()]
  def pending_ids(limit) do
    Download
    |> where([d], d.import_failure_reason == "path_mapping_mismatch")
    |> where([d], not is_nil(d.import_failed_at))
    |> where([d], not is_nil(d.import_reported_path))
    |> where([d], is_nil(d.path_mapping_searched_at))
    |> order_by([d], asc: d.id)
    |> limit(^limit)
    |> select([d], d.id)
    |> Repo.all()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case pending_ids(@default_batch_size) do
      [] ->
        Logger.info("Path-mapping suggestion backfill complete, no rows pending")
        :ok

      ids ->
        # Mount detection probes every candidate mount, so do it once per batch.
        roots = PathMapping.search_roots()
        Enum.each(ids, &backfill_one(&1, roots))

        # Every selected row was either stamped by backfill_one/2 or changed
        # under it (retried, or re-failed and searched by MediaImport.Failure),
        # so it is no longer pending and the next batch is new rows. That is
        # what makes this reschedule terminate.
        %{} |> new(schedule_in: 5, unique: [states: @reschedule_unique_states]) |> Oban.insert()
        :ok
    end
  end

  # The search runs for up to seconds, so the row can change under it: a retry
  # clears the suggestion, a new failure gets its own search from
  # MediaImport.Failure. The write is therefore conditional on the row still
  # being pending for the path that was searched. Zero rows updated means the
  # row is no longer this job's business.
  @doc false
  def backfill_one(id, roots) do
    case Repo.get(Download, id) do
      %Download{import_reported_path: path} when is_binary(path) ->
        write_suggestion(id, path, PathMapping.suggestion_attrs(path, roots))

      _gone ->
        :ok
    end
  end

  @doc false
  def write_suggestion(id, path, attrs) do
    Download
    |> where([d], d.id == ^id and d.import_reported_path == ^path)
    |> where([d], is_nil(d.path_mapping_searched_at))
    |> Repo.update_all(set: Map.to_list(attrs))

    :ok
  end
end
