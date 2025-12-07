defmodule Mydia.Jobs.EventCleanupTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query

  alias Mydia.Jobs.EventCleanup
  alias Mydia.Events
  alias Mydia.Events.Event

  # Helper to backdate an event's inserted_at using Ecto (database-agnostic)
  defp backdate_event(event, datetime) do
    from(e in Event, where: e.id == ^event.id)
    |> Mydia.Repo.update_all(set: [inserted_at: datetime])
  end

  describe "perform/1" do
    test "successfully cleans up events with no events in database" do
      assert :ok = perform_job(EventCleanup, %{})
    end

    test "deletes events older than retention period" do
      # Create old events (100 days ago)
      old_date = DateTime.utc_now() |> DateTime.add(-100, :day)

      {:ok, old_event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user"
        })

      # Manually update inserted_at to be old
      backdate_event(old_event, old_date)

      # Create recent event
      {:ok, _recent_event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.updated",
          actor_type: :user,
          actor_id: "test-user"
        })

      # Run cleanup job (default 90 days retention)
      assert :ok = perform_job(EventCleanup, %{})

      # Old event should be deleted
      refute Events.list_events() |> Enum.any?(&(&1.id == old_event.id))

      # Recent event should still exist
      assert length(Events.list_events()) == 1
    end

    test "uses configured retention days" do
      # Set retention to 30 days
      Application.put_env(:mydia, :event_retention_days, 30)

      # Create event that's 50 days old
      old_date = DateTime.utc_now() |> DateTime.add(-50, :day)

      {:ok, old_event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user"
        })

      # Manually update inserted_at
      backdate_event(old_event, old_date)

      # Run cleanup job
      assert :ok = perform_job(EventCleanup, %{})

      # Event should be deleted (50 days > 30 days retention)
      assert Enum.empty?(Events.list_events())

      # Reset config
      Application.put_env(:mydia, :event_retention_days, 90)
    end

    test "keeps events within retention period" do
      # Create event that's 80 days old (within 90 day retention)
      date = DateTime.utc_now() |> DateTime.add(-80, :day)

      {:ok, event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: "test-user"
        })

      # Manually update inserted_at
      backdate_event(event, date)

      # Run cleanup job (default 90 days retention)
      assert :ok = perform_job(EventCleanup, %{})

      # Event should still exist
      assert length(Events.list_events()) == 1
    end
  end
end
