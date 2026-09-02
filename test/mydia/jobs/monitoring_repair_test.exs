defmodule Mydia.Jobs.MonitoringRepairTest do
  # Drives an isolated Oban instance, so these run serially.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query
  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Events.Event
  alias Mydia.Jobs.MonitoringRepair
  alias Mydia.Media.MediaItem

  # perform/1 reschedules itself whenever it processes at least one row. The app
  # skips Oban in test (engine: false), so that insert needs a locally started
  # instance; mirrors the setup in hdr_backfill_test.exs.
  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
    :ok
  end

  # events.inserted_at is :utc_datetime (second precision) and events.id is a
  # random UUID, so two events written in the same second tie on the timestamp
  # and the desc: e.id tiebreak is not chronological. Every helper here stamps
  # an explicit time so ordering is deterministic instead of a coin flip.
  defp stamp(event, seconds_ago), do: stamp_at(event, -seconds_ago)

  defp stamp_forward(event, seconds_ahead), do: stamp_at(event, seconds_ahead)

  defp stamp_at(event, offset_seconds) do
    at =
      DateTime.utc_now()
      |> DateTime.add(offset_seconds, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(e in Event, where: e.id == ^event.id)
      |> Repo.update_all(set: [inserted_at: at])

    event
  end

  # Writes an event directly. The production reason strings come from the
  # LiveView toggles in media_live/index.ex and show/episode_events.ex.
  defp record_update(item, reason, seconds_ago) do
    {:ok, event} =
      Events.create_event(%{
        category: "media",
        type: "media_item.updated",
        actor_type: :user,
        actor_id: "test-operator",
        resource_type: "media_item",
        resource_id: item.id,
        metadata: %{"title" => item.title, "media_type" => item.type, "reason" => reason}
      })

    stamp(event, seconds_ago)
  end

  defp record_monitoring_changed(item, monitored, seconds_ago) do
    :ok = Events.media_item_monitoring_changed(item, monitored, :user, "test-operator")

    [event] =
      Events.list_events(
        type: "media_item.monitoring_changed",
        resource_type: "media_item",
        resource_id: item.id
      )

    stamp(event, seconds_ago)
  end

  defp monitored?(id), do: Repo.get!(MediaItem, id).monitored

  describe "pending_ids/1" do
    test "selects a monitored item whose last decision was a disable" do
      item = media_item_fixture(%{title: "Halloway Bend", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      assert MonitoringRepair.pending_ids(10) == [item.id]
    end

    test "ignores an item whose last decision was an enable" do
      item = media_item_fixture(%{title: "Ashgrove Lane", monitored: true})
      record_update(item, "Monitoring disabled", 300)
      record_update(item, "Monitoring enabled", 120)

      assert MonitoringRepair.pending_ids(10) == []
    end

    test "ignores an item with no monitoring decision on record" do
      item = media_item_fixture(%{title: "Pemberton Row", monitored: true})
      record_update(item, "Metadata enriched", 300)

      assert MonitoringRepair.pending_ids(10) == []
    end

    test "ignores an item with no events at all" do
      _item = media_item_fixture(%{title: "Ellery Crossing", monitored: true})

      assert MonitoringRepair.pending_ids(10) == []
    end

    test "ignores an item that is already unmonitored" do
      item = media_item_fixture(%{title: "Cobbler's Rest", monitored: false})
      record_update(item, "Monitoring disabled", 300)

      assert MonitoringRepair.pending_ids(10) == []
    end

    # This is the case the design's dropped third condition would have missed.
    test "selects an item with unrelated events after the disable" do
      item = media_item_fixture(%{title: "Winterhold Mill", monitored: true})
      record_update(item, "Monitoring disabled", 300)
      record_update(item, "Metadata enriched", 200)
      record_update(item, "Metadata refreshed", 100)

      assert MonitoringRepair.pending_ids(10) == [item.id]
    end

    test "reads a monitoring_changed event as a decision" do
      item = media_item_fixture(%{title: "Salter's Cross", monitored: true})
      record_monitoring_changed(item, false, 300)

      assert MonitoringRepair.pending_ids(10) == [item.id]
    end

    test "a monitoring_changed enable outranks an earlier disable" do
      item = media_item_fixture(%{title: "Thistledown Way", monitored: true})
      record_update(item, "Monitoring disabled", 300)
      record_monitoring_changed(item, true, 120)

      assert MonitoringRepair.pending_ids(10) == []
    end

    test "honours the limit" do
      items =
        for n <- 1..3 do
          item = media_item_fixture(%{title: "Batch Item #{n}", monitored: true})
          record_update(item, "Monitoring disabled", 300)
          item
        end

      assert length(items) == 3
      assert length(MonitoringRepair.pending_ids(2)) == 2
    end
  end

  describe "repair_one/1" do
    test "does not flip an item whose decision became an enable after selection" do
      item = media_item_fixture(%{title: "Quietwood Fen", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      # This is exactly what pending_ids/1 selects on.
      assert MonitoringRepair.pending_ids(10) == [item.id]

      # Simulates the race directly: an operator re-enables monitoring,
      # recording a newer decision, between selection and repair_one/1's
      # write. No sleeps or concurrent processes needed, since repair_one/1
      # re-reads the decision itself immediately before writing.
      record_update(item, "Monitoring enabled", 120)

      assert :ok = MonitoringRepair.repair_one(item.id)

      assert monitored?(item.id)

      # No monitoring_changed event was fabricated for a write that never
      # happened; that would corrupt the decision history this worker reads.
      assert Events.list_events(
               type: "media_item.monitoring_changed",
               resource_type: "media_item",
               resource_id: item.id
             ) == []
    end

    test "flips an item whose latest decision is still a disable" do
      item = media_item_fixture(%{title: "Amberfield Row", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      assert :ok = MonitoringRepair.repair_one(item.id)

      refute monitored?(item.id)

      assert [event] =
               Events.list_events(
                 type: "media_item.monitoring_changed",
                 resource_type: "media_item",
                 resource_id: item.id
               )

      assert event.metadata["monitored"] == false
    end

    test "returns :ok for an id that no longer exists" do
      assert :ok = MonitoringRepair.repair_one(Ecto.UUID.generate())
    end

    test "the update and its decision event commit or roll back together" do
      item = media_item_fixture(%{title: "Wrenfield Close", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      # repair_one/1 is just `Repo.transaction(fn -> repair_one_tx(id) end)`.
      # Driving repair_one_tx/1 through our own transaction here is
      # equivalent, and lets the test force a rollback right after the
      # write instead of relying on real concurrency or a sleep to land one
      # mid-transaction.
      result =
        Repo.transaction(fn ->
          case MonitoringRepair.repair_one_tx(item.id) do
            :updated -> Repo.rollback(:forced_for_test)
            other -> other
          end
        end)

      assert result == {:error, :forced_for_test}

      # The update did not survive the rollback.
      assert monitored?(item.id)

      # Nor did the decision event. If the two writes were not part of the
      # same transaction, this event would still be here even though the
      # update it describes never happened, and it would become the item's
      # newest "decision" on the very next pending_ids/1 run: the same
      # class of self-inflicted bug getmydia/mydia#653 is about.
      assert Events.list_events(
               type: "media_item.monitoring_changed",
               resource_type: "media_item",
               resource_id: item.id
             ) == []
    end
  end

  describe "perform/1" do
    test "restores the item and records the restoration" do
      item = media_item_fixture(%{title: "Merrow Quay", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})

      refute monitored?(item.id)

      assert [event] =
               Events.list_events(
                 type: "media_item.monitoring_changed",
                 resource_type: "media_item",
                 resource_id: item.id
               )

      assert event.metadata["monitored"] == false
      assert event.actor_id == "monitoring_repair"
      # :job routes through format_job_name/1 in the Activity Feed ("Monitoring
      # Repair"); :system would collapse to a generic "System" label and
      # discard the actor id entirely.
      assert event.actor_type == :job
    end

    test "leaves an item whose last decision was an enable alone" do
      item = media_item_fixture(%{title: "Bramble Court", monitored: true})
      record_update(item, "Monitoring disabled", 300)
      record_update(item, "Monitoring enabled", 120)

      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})

      assert monitored?(item.id)
    end

    test "a second run changes nothing" do
      item = media_item_fixture(%{title: "Fallow Green", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      events_before_repair =
        Events.list_events(resource_type: "media_item", resource_id: item.id)

      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})
      refute monitored?(item.id)

      # The repair must write exactly ONE event (the explicit
      # monitoring_changed decision), not that event plus a second
      # media_item.updated from going through Media.update_media_item/3. A
      # count scoped to `type: "media_item.monitoring_changed"` would not
      # catch the second event, since it is a different type.
      events_after_first_run =
        Events.list_events(resource_type: "media_item", resource_id: item.id)

      assert length(events_after_first_run) == length(events_before_repair) + 1

      assert MonitoringRepair.pending_ids(10) == []
      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})

      refute monitored?(item.id)

      # One restoration, not two: the second run adds nothing at all.
      assert length(Events.list_events(resource_type: "media_item", resource_id: item.id)) ==
               length(events_after_first_run)
    end

    test "a manual re-enable after the repair is not undone" do
      item = media_item_fixture(%{title: "Otterly Vale", monitored: true})
      record_update(item, "Monitoring disabled", 300)

      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})
      refute monitored?(item.id)

      # The repair's own monitoring_changed event was written just now, so the
      # manual re-enable has to be stamped later than it to be the newest
      # decision at second precision.
      {:ok, reenabled} =
        Mydia.Media.update_media_item(Repo.get!(MediaItem, item.id), %{monitored: true},
          reason: "Monitoring enabled"
        )

      # Selected by reason, not by position: the repair wrote its own
      # media_item.updated event in the same second, so "newest first" cannot
      # tell the two apart.
      enable_event =
        Events.list_events(
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: item.id
        )
        |> Enum.find(&(&1.metadata["reason"] == "Monitoring enabled"))

      assert enable_event
      stamp_forward(enable_event, 60)

      assert reenabled.monitored
      assert MonitoringRepair.pending_ids(10) == []

      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})
      assert monitored?(item.id)
    end
  end

  describe "enqueue_once/0" do
    test "returns :ok and inserts one job" do
      assert :ok = MonitoringRepair.enqueue_once()
      assert_enqueued(worker: MonitoringRepair)
    end
  end
end
