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

      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})
      refute monitored?(item.id)

      assert MonitoringRepair.pending_ids(10) == []
      assert :ok = MonitoringRepair.perform(%Oban.Job{args: %{}})

      refute monitored?(item.id)

      # One restoration, not two.
      assert length(
               Events.list_events(
                 type: "media_item.monitoring_changed",
                 resource_type: "media_item",
                 resource_id: item.id
               )
             ) == 1
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
