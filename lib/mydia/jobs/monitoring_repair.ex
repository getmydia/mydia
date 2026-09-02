defmodule Mydia.Jobs.MonitoringRepair do
  @moduledoc """
  One-shot worker restoring monitoring on items the enricher silently enabled.

  `Mydia.Library.MetadataEnricher` used to write `monitored: true` on the update
  path, so any scan that re-enriched an item the operator had unmonitored turned
  monitoring back on without recording a decision (getmydia/mydia#653). The
  setting was destroyed but the record of it was not: the monitoring toggles
  write `reason: "Monitoring enabled"` or `"Monitoring disabled"` into event
  metadata, and events are retained for 90 days by default.

  An item is repaired when two facts hold: it is monitored now, and the most
  recent monitoring decision on record was a disable. Nothing else is checked,
  because the enricher was the only writer that could produce that combination.
  Every other path that sets `monitored` on an existing item records a decision
  (`Media.update_media_items_monitored/3`, `Media.update_media_items_batch/3`,
  and the LiveView toggles), and approving a media request for an item already
  in the library links the row without writing to it.

  `pending_ids/1` selects a batch once per run, but the operator can act on
  any of those items before `repair_one/1` gets to them. So the decision is
  re-checked, via `latest_decision/1`, immediately before the write, inside
  the same `Repo.transaction/1` as the write itself. If a newer decision
  appeared (an operator re-enabling monitoring, most importantly) the item is
  skipped rather than flipped, and no event is emitted for it: writing an
  event for a skipped item would fabricate a decision that was never made and
  corrupt the very history this worker reads.

  Idempotent with no stamp column. The restoration emits its own
  `monitoring_changed` event, which becomes the item's latest decision, and the
  item is no longer monitored, so a second pass cannot select it. A manual
  re-enable afterwards is likewise a later decision, so this never undoes the
  operator. That is why, unlike `Mydia.Jobs.HdrBackfill`, this needs no
  migration.

  Items whose disable predates the event retention window carry no record and
  are left alone. They cannot be recovered.

  One limitation worth knowing: `events.inserted_at` is `:utc_datetime`, so it
  holds seconds, and `events.id` is a random UUID. Two decisions recorded in the
  same second therefore order arbitrarily. In production a disable and an enable
  a second apart is not a real scenario, and the worst case is that one item is
  left monitored, which the operator can fix from the UI. The tests stamp
  explicit timestamps rather than rely on it.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Mirrors Mydia.Jobs.HdrBackfill: with :executing included, a restart while
    # a pass is mid-batch cannot stack a second one on top.
    unique: [
      period: 300,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Mydia.Events
  alias Mydia.Events.Event
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  require Logger

  @default_batch_size 100

  # How many media item ids go into one `resource_id in (...)` list. Well under
  # SQLite's bound-parameter ceiling, and small enough that a library with tens
  # of thousands of items does not pull its whole event history at once.
  @id_chunk_size 200

  # See Mydia.Jobs.HdrBackfill for why the reschedule drops :executing from the
  # worker-level states: Oban's uniqueness check has no exclusion for the row
  # currently running this code, so the follow-up insert would match its own
  # job and the repair would stop after one batch.
  @reschedule_unique_states [:suspended, :available, :scheduled, :retryable]

  @enable_reason "Monitoring enabled"
  @disable_reason "Monitoring disabled"

  @doc """
  Enqueues the one-shot repair. Called once at boot.

  Deliberately never raises, for the reason spelled out in
  `Mydia.Jobs.HdrBackfill.enqueue_once/0`: `Mydia.Application.start/2` has no
  top-level rescue, and losing the whole application to a repair job that can
  safely run on the next boot is a bad trade for a self-hosted operator with no
  easy way to diagnose a boot crash.
  """
  @spec enqueue_once() :: :ok
  def enqueue_once do
    %{} |> new() |> Oban.insert()
    :ok
  rescue
    error ->
      Logger.warning("Monitoring repair: failed to enqueue on boot", error: inspect(error))
      :ok
  end

  @doc """
  Ids of media items whose monitoring should be restored.

  Ordered by `m.id asc`, which is deterministic but arbitrary: `id` is a
  random UUIDv4, not a timestamp, so this is not "oldest first" or any other
  meaningful order. Nothing depends on the order beyond it being stable across
  the paged `disabled_in_chunk/1` calls within a single run.

  The reason lives inside `Event.metadata`, which is a
  `Mydia.Settings.JsonMapType`: a map serialized into a **text** column on both
  SQLite and PostgreSQL. There is no portable JSON operator for it, so the query
  narrows by type and resource and the reason match runs in Elixir.
  """
  @spec pending_ids(pos_integer()) :: [binary()]
  def pending_ids(limit) do
    MediaItem
    |> where([m], m.monitored == true)
    |> order_by([m], asc: m.id)
    |> select([m], m.id)
    |> Repo.all()
    |> Enum.chunk_every(@id_chunk_size)
    |> Enum.reduce_while([], fn chunk, acc ->
      found = acc ++ disabled_in_chunk(chunk)

      if length(found) >= limit do
        {:halt, Enum.take(found, limit)}
      else
        {:cont, found}
      end
    end)
    |> Enum.take(limit)
  end

  # Shared by the batch selection query below and by `latest_decision/1`, the
  # single-item recheck `repair_one/1` runs immediately before it writes, so
  # the two paths cannot drift apart on what counts as "a decision event for
  # this item".
  defp decision_events_query(ids) do
    Event
    |> where([e], e.resource_type == "media_item")
    |> where([e], e.resource_id in ^ids)
    |> where([e], e.type in ["media_item.updated", "media_item.monitoring_changed"])
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> select([e], {e.resource_id, e.type, e.metadata})
  end

  # One query per chunk of ids, not one per item. Chunking keeps the `in` list
  # clear of SQLite's bound-parameter ceiling on a large library.
  defp disabled_in_chunk(ids) do
    ids
    |> decision_events_query()
    |> Repo.all()
    |> Enum.group_by(fn {resource_id, _type, _metadata} -> resource_id end)
    |> Enum.filter(fn {_resource_id, events} ->
      # The group preserves the newest-first order of the query, so the first
      # event that is a decision at all is the most recent one.
      Enum.find_value(events, &decision/1) == :disable
    end)
    |> Enum.map(fn {resource_id, _events} -> resource_id end)
    # Repo.all returned rows grouped arbitrarily; restore the id order the
    # caller asked for so the batch is deterministic.
    |> then(fn matched -> Enum.filter(ids, &(&1 in matched)) end)
  end

  @doc """
  The latest monitoring decision recorded for one media item: `:enable`,
  `:disable`, or `nil` when no decision is on record.

  Used to re-check a single item immediately before `repair_one/1` writes to
  it, so a decision recorded after `pending_ids/1` selected the batch is not
  missed.
  """
  @spec latest_decision(binary()) :: :enable | :disable | nil
  def latest_decision(id) do
    [id]
    |> decision_events_query()
    |> Repo.all()
    |> Enum.find_value(&decision/1)
  end

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    batch_size = Application.get_env(:mydia, :monitoring_repair_batch_size, @default_batch_size)

    case pending_ids(batch_size) do
      [] ->
        Logger.info("Monitoring repair complete, no items pending")
        :ok

      ids ->
        Enum.each(ids, &repair_one/1)

        Logger.info("Monitoring repair restored #{length(ids)} item(s)")

        # Reschedule until the set drains. Singular insert/1, not insert_all/1,
        # which bypasses the worker's unique constraint.
        %{} |> new(schedule_in: 5, unique: [states: @reschedule_unique_states]) |> Oban.insert()
        :ok
    end
  end

  @doc """
  Restores monitoring on one media item, if its decision still says so.

  Public (rather than the batch-only `defp` it started as) so a test can
  drive the exact race this guards against: write a newer decision for an
  item, then call this directly with its id, without needing real
  concurrency to land the write in between `pending_ids/1`'s selection and
  this function's own write.

  `pending_ids/1` selects the batch from a query taken before this job
  started running. An operator can act on any of those items before this
  function reaches them, most importantly by re-enabling monitoring, which
  records a fresh "enable" decision. Writing `monitored: false` without
  looking again would silently undo that operator action, which is exactly
  the class of bug getmydia/mydia#653 is about, so the recheck below runs
  immediately before the write, inside the same transaction as the write.

  The decision event is written inside that same transaction, not after it
  commits. `Events.media_item_monitoring_changed/4` calls
  `Events.create_event_async/1`, which writes synchronously on the caller's
  connection whenever `Repo.in_transaction?/0` is true instead of casting to
  the async `Events.Writer`, so the update and its event commit or roll back
  together. Writing the event after the transaction would leave a window
  where an operator's re-enable lands between the commit and the event
  write: the repair's disable event would then become the item's newest
  decision while the item is actually monitored, and `pending_ids/1` would
  select it again on the next run and undo the operator a second time. That
  is the same bug this worker exists to fix.
  """
  @spec repair_one(binary()) :: :ok
  def repair_one(id) do
    case Repo.transaction(fn -> repair_one_tx(id) end) do
      {:ok, :updated} ->
        :ok

      {:ok, {:error, changeset}} ->
        Logger.warning("Monitoring repair failed for item",
          media_item_id: id,
          errors: inspect(changeset.errors)
        )

        :ok

      {:ok, :skipped} ->
        :ok
    end
  end

  @doc """
  The transaction body shared by `repair_one/1`: recheck, update, and (on a
  successful update) write the decision event, all on the caller's
  connection.

  Public, like `repair_one/1`, purely for testability: a test can wrap this
  in its own `Repo.transaction/1` and force a rollback after it returns
  `:updated`, then assert that neither the update nor the event survived.
  That is the cleanest deterministic way to prove the two writes are
  atomic, since production never rolls this transaction back on the
  success path (there is nothing to force the race in real time without
  concurrency or a sleep). `repair_one/1` remains the only caller in
  production code.
  """
  @spec repair_one_tx(binary()) :: :updated | {:error, Ecto.Changeset.t()} | :skipped
  def repair_one_tx(id) do
    with %MediaItem{} = item <- Repo.get(MediaItem, id) || :not_found,
         :disable <- latest_decision(id) do
      # Deliberately not Media.update_media_item/3: it always emits its own
      # media_item.updated event, which would land right next to the
      # explicit monitoring_changed event below and show the operator two
      # near-duplicate entries in the Activity Feed and item history for
      # every repaired item. Building and applying the changeset directly
      # keeps this write to exactly the one event that makes it idempotent.
      case Repo.update(MediaItem.changeset(item, %{monitored: false})) do
        {:ok, updated} ->
          # The explicit decision event is what makes this idempotent: it
          # becomes the item's latest monitoring decision, so a later pass
          # cannot select the row again. Only emitted when the guarded
          # update above actually ran, so a skipped item leaves no event
          # behind. Written inside this transaction (see the moduledoc and
          # repair_one/1 above) so the update and the event are atomic.
          Events.media_item_monitoring_changed(updated, false, :job, "monitoring_repair")
          :updated

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      :not_found ->
        :skipped

      _newer_decision ->
        Logger.info(
          "Monitoring repair skipped item: a newer decision was recorded after selection",
          media_item_id: id
        )

        :skipped
    end
  end

  # Returns :enable, :disable, or nil for a row that is not a decision.
  # Enum.find_value/2 stops at the first non-nil, which is the most recent
  # decision because the query ordered newest first.
  defp decision({_resource_id, "media_item.monitoring_changed", metadata}) do
    case Map.get(metadata, "monitored") do
      true -> :enable
      false -> :disable
      _ -> nil
    end
  end

  defp decision({_resource_id, "media_item.updated", metadata}) do
    case Map.get(metadata, "reason") do
      @enable_reason -> :enable
      @disable_reason -> :disable
      _ -> nil
    end
  end

  defp decision(_row), do: nil
end
