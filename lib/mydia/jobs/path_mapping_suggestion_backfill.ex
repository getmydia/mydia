defmodule Mydia.Jobs.PathMappingSuggestionBackfill do
  @moduledoc """
  One-shot worker that computes the stored path-mapping suggestion for
  downloads that failed with `path_mapping_mismatch` before suggestions were
  stored (#1315). New failures get theirs from `Mydia.Jobs.MediaImport.Failure`.

  Selection is by row state, so the worker is idempotent: it takes mismatch
  rows whose `path_mapping_searched_at` is nil, and every outcome stamps it,
  including a search that found nothing.

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

  alias Mydia.Downloads
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

        # Every row in the batch was written or, if the write failed, stamped
        # by backfill_one/2, so none stays pending and the next batch is new
        # rows. That is what makes this reschedule terminate.
        %{} |> new(schedule_in: 5, unique: [states: @reschedule_unique_states]) |> Oban.insert()
        :ok
    end
  end

  defp backfill_one(id, roots) do
    case Repo.get(Download, id) do
      %Download{import_reported_path: path} = download when is_binary(path) ->
        case Downloads.update_download(download, PathMapping.suggestion_attrs(path, roots)) do
          {:ok, _download} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "Path-mapping suggestion backfill: could not store suggestion for download " <>
                "#{id}: #{inspect(changeset.errors)}; marking it searched"
            )

            stamp_searched(id)
        end

      _gone ->
        :ok
    end
  end

  # Bypasses the changeset so a row that cannot validate still leaves the
  # pending set.
  defp stamp_searched(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Download
    |> where([d], d.id == ^id)
    |> Repo.update_all(set: [path_mapping_searched_at: now])

    :ok
  end
end
