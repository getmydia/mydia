defmodule Mydia.Jobs.MetadataBackfill do
  @moduledoc """
  Repairs media items that need a metadata refresh to become correct.

  Two cases qualify. Items stored with no `metadata` at all render as an empty
  poster placeholder forever; approving a media request used to create them,
  which is fixed at the source in `Mydia.MediaRequests.approve_request/3`. TV
  shows holding one provider id and not the other make Discover show an Add
  button for something already in the library, and the add that follows dies on
  the `tvdb_id` unique index.

  Runs daily. The query matches nothing once the library is repaired, so the
  job settles into costing one read, and a self-hosted operator never has to
  find and repair these by hand. Idempotent and safe to re-run.
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
      from(m in MediaItem,
        where:
          is_nil(m.metadata) or
            (m.type == "tv_show" and
               ((is_nil(m.tmdb_id) and not is_nil(m.tvdb_id)) or
                  (is_nil(m.tvdb_id) and not is_nil(m.tmdb_id)))),
        select: struct(m, [:id, :metadata]),
        order_by: [asc: m.title]
      )
      |> Repo.all()
      |> Enum.filter(&needs_backfill?/1)
      |> Enum.map(& &1.id)

    total = length(ids)

    if total == 0 do
      :ok
    else
      Logger.info("[MetadataBackfill] Found #{total} media items needing repair")

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

  # The stored metadata is its own marker. Metadata written before
  # cross-provider id storage has `external_ids` nil, which means we have never
  # asked its provider for a cross-reference. Anything written since always
  # carries the map, even when every entry inside is nil, so a show that
  # neither provider cross-references drops out of this filter after one
  # refresh instead of being re-enqueued every night.
  defp needs_backfill?(%MediaItem{metadata: nil}), do: true
  defp needs_backfill?(%MediaItem{metadata: %{external_ids: ids}}) when is_map(ids), do: false
  defp needs_backfill?(%MediaItem{}), do: true

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
