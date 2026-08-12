defmodule Mydia.Jobs.MetadataBackfill do
  @moduledoc """
  Enqueues a metadata refresh for every media item stored without metadata.

  Approving a media request used to create a bare row with no `metadata`, which
  renders as an empty poster placeholder forever. That is fixed at the source in
  `Mydia.MediaRequests.approve_request/3`, but libraries already carry the
  damaged rows, and a self-hosted operator should not have to find and repair
  them by hand.

  Runs daily. Once a library is repaired the query returns nothing and the job
  costs one empty read, so it also self-heals if nil-metadata items appear again
  from any other cause. Idempotent and safe to re-run.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [
      period: 86_400,
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger

  import Ecto.Query

  alias Mydia.Jobs.MetadataRefresh
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  # Delay between batches to avoid hammering the relay once the refreshes run.
  @batch_delay_ms 2_000
  @batch_size 10

  @spec perform(Oban.Job.t()) :: :ok
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    ids =
      from(m in MediaItem, where: is_nil(m.metadata), select: m.id, order_by: [asc: m.title])
      |> Repo.all()

    total = length(ids)

    if total == 0 do
      :ok
    else
      Logger.info("[MetadataBackfill] Found #{total} media items without metadata")

      ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index()
      |> Enum.each(fn {batch, batch_index} ->
        if batch_index > 0 do
          Process.sleep(@batch_delay_ms)
        end

        Enum.each(batch, &enqueue_refresh/1)
      end)

      Logger.info("[MetadataBackfill] Enqueued #{total} metadata refreshes")

      :ok
    end
  end

  defp enqueue_refresh(media_item_id) do
    # Singular Oban.insert/1, never insert_all/1: uniqueness on Basic and Lite
    # is only applied by the singular path, so insert_all would queue duplicate
    # refreshes on every daily run.
    %{media_item_id: media_item_id}
    |> MetadataRefresh.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[MetadataBackfill] Could not enqueue refresh for #{media_item_id}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
