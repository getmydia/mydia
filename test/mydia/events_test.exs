defmodule Mydia.EventsTest do
  use Mydia.DataCase

  alias Mydia.Events
  alias Mydia.Events.Event
  alias Phoenix.PubSub

  describe "create_event/1" do
    test "creates event with valid attributes" do
      attrs = %{
        category: "media",
        type: "media_item.added",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        resource_type: "media_item",
        resource_id: Ecto.UUID.generate(),
        severity: :info,
        metadata: %{"title" => "Test Movie"}
      }

      assert {:ok, %Event{} = event} = Events.create_event(attrs)
      assert event.category == "media"
      assert event.type == "media_item.added"
      assert event.actor_type == :user
      assert event.actor_id == attrs.actor_id
      assert event.resource_type == "media_item"
      assert event.resource_id == attrs.resource_id
      assert event.severity == :info
      assert event.metadata == %{"title" => "Test Movie"}
      assert event.inserted_at
    end

    test "creates event with minimal required fields" do
      attrs = %{
        category: "system",
        type: "job.executed"
      }

      assert {:ok, %Event{} = event} = Events.create_event(attrs)
      assert event.category == "system"
      assert event.type == "job.executed"
      assert is_nil(event.actor_type)
      assert is_nil(event.actor_id)
      assert is_nil(event.resource_type)
      assert is_nil(event.resource_id)
      assert event.severity == :info
      assert event.metadata == %{}
    end

    test "returns error for invalid category format" do
      attrs = %{
        category: "InvalidCategory",
        type: "media_item.added"
      }

      assert {:error, changeset} = Events.create_event(attrs)
      assert "must be lowercase with underscores" in errors_on(changeset).category
    end

    test "returns error for invalid type format" do
      attrs = %{
        category: "media",
        type: "invalidtype"
      }

      assert {:error, changeset} = Events.create_event(attrs)
      assert "must be format: category.action" in errors_on(changeset).type
    end

    test "returns error when category is missing" do
      attrs = %{type: "media_item.added"}

      assert {:error, changeset} = Events.create_event(attrs)
      assert "can't be blank" in errors_on(changeset).category
    end

    test "returns error when type is missing" do
      attrs = %{category: "media"}

      assert {:error, changeset} = Events.create_event(attrs)
      assert "can't be blank" in errors_on(changeset).type
    end

    test "returns error when actor_type is set but actor_id is missing" do
      attrs = %{
        category: "media",
        type: "media_item.added",
        actor_type: :user
      }

      assert {:error, changeset} = Events.create_event(attrs)
      assert "must be provided when actor_type is set" in errors_on(changeset).actor_id
    end

    test "broadcasts event to PubSub subscribers" do
      # Subscribe to events topic
      PubSub.subscribe(Mydia.PubSub, "events:all")

      attrs = %{
        category: "media",
        type: "media_item.added"
      }

      assert {:ok, event} = Events.create_event(attrs)

      # Verify broadcast received
      assert_receive {:event_created, ^event}, 100
    end
  end

  describe "create_event_async/1" do
    test "creates event asynchronously" do
      attrs = %{
        category: "downloads",
        type: "download.initiated",
        metadata: %{"title" => "Test Download"}
      }

      assert :ok = Events.create_event_async(attrs)

      # Wait for async operation to complete
      Process.sleep(100)

      # Verify event was created
      events = Events.list_events(category: "downloads")
      assert length(events) == 1
      assert hd(events).type == "download.initiated"
    end

    test "does not block caller on error" do
      invalid_attrs = %{category: "Invalid"}

      # Should return :ok immediately even though it will fail
      assert :ok = Events.create_event_async(invalid_attrs)
    end

    test "broadcasts event to PubSub subscribers" do
      # Allow async task to use the same sandboxed connection
      parent = self()

      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Mydia.Repo, parent, self())
        PubSub.subscribe(Mydia.PubSub, "events:all")

        attrs = %{
          category: "media",
          type: "media_item.updated"
        }

        Events.create_event_async(attrs)

        # Should eventually receive the broadcast
        receive do
          {:event_created, %Event{type: "media_item.updated"}} -> :ok
        after
          300 -> raise "Did not receive event broadcast"
        end
      end)
      |> Task.await()
    end
  end

  describe "list_events/1" do
    setup do
      user_id = Ecto.UUID.generate()
      media_item_id = Ecto.UUID.generate()

      # Create various test events
      {:ok, event1} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          actor_type: :user,
          actor_id: user_id,
          resource_type: "media_item",
          resource_id: media_item_id,
          severity: :info
        })

      {:ok, event2} =
        Events.create_event(%{
          category: "media",
          type: "media_item.updated",
          actor_type: :user,
          actor_id: user_id,
          resource_type: "media_item",
          resource_id: media_item_id,
          severity: :info
        })

      {:ok, event3} =
        Events.create_event(%{
          category: "downloads",
          type: "download.initiated",
          actor_type: :user,
          actor_id: user_id,
          severity: :info
        })

      {:ok, event4} =
        Events.create_event(%{
          category: "system",
          type: "job.failed",
          actor_type: :job,
          actor_id: "metadata_refresh",
          severity: :error
        })

      %{
        user_id: user_id,
        media_item_id: media_item_id,
        events: [event1, event2, event3, event4]
      }
    end

    test "lists all events by default", %{events: events} do
      result = Events.list_events()
      assert length(result) == 4

      # All events should be present (order within same timestamp is non-deterministic with UUIDv4)
      result_ids = Enum.map(result, & &1.id) |> MapSet.new()
      event_ids = Enum.map(events, & &1.id) |> MapSet.new()
      assert result_ids == event_ids
    end

    test "filters by category" do
      result = Events.list_events(category: "media")
      assert length(result) == 2
      assert Enum.all?(result, &(&1.category == "media"))
    end

    test "filters by type" do
      result = Events.list_events(type: "media_item.added")
      assert length(result) == 1
      assert hd(result).type == "media_item.added"
    end

    test "filters by actor_type only", %{} do
      result = Events.list_events(actor_type: :user)
      assert length(result) == 3
      assert Enum.all?(result, &(&1.actor_type == :user))
    end

    test "filters by actor_type and actor_id", %{user_id: user_id} do
      result = Events.list_events(actor_type: :user, actor_id: user_id)
      assert length(result) == 3
      assert Enum.all?(result, &(&1.actor_type == :user && &1.actor_id == user_id))
    end

    test "filters by resource_type only" do
      result = Events.list_events(resource_type: "media_item")
      assert length(result) == 2
      assert Enum.all?(result, &(&1.resource_type == "media_item"))
    end

    test "filters by resource_type and resource_id", %{media_item_id: media_item_id} do
      result = Events.list_events(resource_type: "media_item", resource_id: media_item_id)
      assert length(result) == 2

      assert Enum.all?(
               result,
               &(&1.resource_type == "media_item" && &1.resource_id == media_item_id)
             )
    end

    test "filters by severity" do
      result = Events.list_events(severity: :error)
      assert length(result) == 1
      assert hd(result).severity == :error
    end

    test "filters by date range - since" do
      cutoff = DateTime.utc_now() |> DateTime.add(-1, :second)
      result = Events.list_events(since: cutoff)
      assert length(result) == 4
    end

    test "filters by date range - until" do
      cutoff = DateTime.utc_now() |> DateTime.add(1, :second)
      result = Events.list_events(until: cutoff)
      assert length(result) == 4
    end

    test "filters by date range - since and until" do
      since = DateTime.utc_now() |> DateTime.add(-10, :second)
      until_time = DateTime.utc_now() |> DateTime.add(10, :second)
      result = Events.list_events(since: since, until: until_time)
      assert length(result) == 4
    end

    test "combines multiple filters", %{user_id: user_id} do
      result = Events.list_events(category: "media", actor_type: :user, actor_id: user_id)
      assert length(result) == 2
      assert Enum.all?(result, &(&1.category == "media" && &1.actor_type == :user))
    end

    test "respects limit option" do
      result = Events.list_events(limit: 2)
      assert length(result) == 2
    end

    test "respects offset option" do
      all_events = Events.list_events()
      result = Events.list_events(offset: 2)
      assert length(result) == 2
      # Should skip first 2 events
      assert Enum.map(result, & &1.id) == Enum.slice(all_events, 2..3) |> Enum.map(& &1.id)
    end

    test "returns empty list when no events match filters" do
      result = Events.list_events(category: "nonexistent")
      assert result == []
    end
  end

  describe "get_resource_events/3" do
    test "retrieves events for specific resource" do
      resource_id = Ecto.UUID.generate()

      {:ok, _event1} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          resource_type: "media_item",
          resource_id: resource_id
        })

      {:ok, _event2} =
        Events.create_event(%{
          category: "media",
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: resource_id
        })

      # Event for different resource
      {:ok, _event3} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          resource_type: "media_item",
          resource_id: Ecto.UUID.generate()
        })

      result = Events.get_resource_events("media_item", resource_id)
      assert length(result) == 2
      assert Enum.all?(result, &(&1.resource_id == resource_id))
    end

    test "respects limit option" do
      resource_id = Ecto.UUID.generate()

      Enum.each(1..5, fn _ ->
        Events.create_event(%{
          category: "media",
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: resource_id
        })
      end)

      result = Events.get_resource_events("media_item", resource_id, limit: 3)
      assert length(result) == 3
    end

    test "can filter by category" do
      resource_id = Ecto.UUID.generate()

      {:ok, _event1} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added",
          resource_type: "media_item",
          resource_id: resource_id
        })

      {:ok, _event2} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          resource_type: "media_item",
          resource_id: resource_id
        })

      result = Events.get_resource_events("media_item", resource_id, category: "media")
      assert length(result) == 1
      assert hd(result).category == "media"
    end
  end

  describe "count_events/1" do
    setup do
      user_id = Ecto.UUID.generate()

      Events.create_event(%{
        category: "media",
        type: "media_item.added",
        actor_type: :user,
        actor_id: user_id
      })

      Events.create_event(%{
        category: "media",
        type: "media_item.updated",
        actor_type: :user,
        actor_id: user_id
      })

      Events.create_event(%{
        category: "downloads",
        type: "download.initiated",
        severity: :info
      })

      Events.create_event(%{
        category: "system",
        type: "job.failed",
        severity: :error
      })

      %{user_id: user_id}
    end

    test "counts all events" do
      assert Events.count_events() == 4
    end

    test "counts events by category" do
      assert Events.count_events(category: "media") == 2
      assert Events.count_events(category: "downloads") == 1
    end

    test "counts events by severity" do
      assert Events.count_events(severity: :info) == 3
      assert Events.count_events(severity: :error) == 1
    end

    test "counts events with multiple filters", %{user_id: user_id} do
      assert Events.count_events(category: "media", actor_type: :user, actor_id: user_id) == 2
    end

    test "returns 0 when no events match" do
      assert Events.count_events(category: "nonexistent") == 0
    end
  end

  describe "delete_old_events/1" do
    test "deletes events older than specified days" do
      # Create old event (simulate by manually setting inserted_at)
      {:ok, old_event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.added"
        })

      # Update inserted_at to 100 days ago
      old_date = DateTime.utc_now() |> DateTime.add(-100, :day)

      Repo.update_all(
        from(e in Event, where: e.id == ^old_event.id),
        set: [inserted_at: old_date]
      )

      # Create recent event
      {:ok, _recent_event} =
        Events.create_event(%{
          category: "media",
          type: "media_item.updated"
        })

      # Delete events older than 90 days
      assert {:ok, 1} = Events.delete_old_events(90)

      # Verify only recent event remains
      events = Events.list_events()
      assert length(events) == 1
      assert hd(events).type == "media_item.updated"
    end

    test "returns count of 0 when no old events exist" do
      Events.create_event(%{
        category: "media",
        type: "media_item.added"
      })

      assert {:ok, 0} = Events.delete_old_events(90)
    end

    test "does not delete events within retention period" do
      Enum.each(1..5, fn _ ->
        Events.create_event(%{
          category: "media",
          type: "media_item.added"
        })
      end)

      assert {:ok, 0} = Events.delete_old_events(90)
      assert Events.count_events() == 5
    end
  end

  describe "helper functions" do
    test "media_item_added/3 creates correct event" do
      user_id = Ecto.UUID.generate()

      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Movie",
        type: "movie",
        year: 2024,
        tmdb_id: 12345
      }

      Events.media_item_added(media_item, :user, user_id)
      Process.sleep(100)

      [event] = Events.list_events(type: "media_item.added")
      assert event.category == "media"
      assert event.type == "media_item.added"
      assert event.actor_type == :user
      assert event.actor_id == user_id
      assert event.resource_type == "media_item"
      assert event.resource_id == media_item.id
      assert event.metadata["title"] == "Test Movie"
      assert event.metadata["media_type"] == "movie"
      assert event.metadata["year"] == 2024
      assert event.metadata["tmdb_id"] == 12345
    end

    test "media_item_updated/4 creates correct event with reason" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Show",
        type: "tv_show"
      }

      Events.media_item_updated(media_item, :job, "metadata_refresh", "Metadata refreshed")
      Process.sleep(100)

      [event] = Events.list_events(type: "media_item.updated")
      assert event.category == "media"
      assert event.actor_type == :job
      assert event.actor_id == "metadata_refresh"
      assert event.metadata["title"] == "Test Show"
      assert event.metadata["media_type"] == "tv_show"
      assert event.metadata["reason"] == "Metadata refreshed"
    end

    test "media_item_updated/3 uses default reason" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Movie",
        type: "movie"
      }

      Events.media_item_updated(media_item, :system, "test")
      Process.sleep(100)

      [event] = Events.list_events(type: "media_item.updated")
      assert event.metadata["reason"] == "Updated"
    end

    test "media_item_removed/3 creates correct event" do
      user_id = Ecto.UUID.generate()

      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Deleted Movie",
        type: "movie"
      }

      Events.media_item_removed(media_item, :user, user_id)
      Process.sleep(100)

      [event] = Events.list_events(type: "media_item.removed")
      assert event.category == "media"
      assert event.type == "media_item.removed"
      assert event.actor_type == :user
      assert event.metadata["title"] == "Deleted Movie"
    end

    test "media_item_monitoring_changed/4 creates correct event" do
      user_id = Ecto.UUID.generate()

      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Monitored Show",
        type: "tv_show"
      }

      Events.media_item_monitoring_changed(media_item, true, :user, user_id)
      Process.sleep(100)

      [event] = Events.list_events(type: "media_item.monitoring_changed")
      assert event.metadata["monitored"] == true
      assert event.metadata["title"] == "Monitored Show"
    end

    test "download_initiated/4 creates correct event" do
      user_id = Ecto.UUID.generate()

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test Download",
        indexer: "test_indexer",
        download_client: "transmission"
      }

      Events.download_initiated(download, :user, user_id)
      Process.sleep(100)

      [event] = Events.list_events(type: "download.initiated")
      assert event.category == "downloads"
      assert event.actor_type == :user
      assert event.metadata["title"] == "Test Download"
      assert event.metadata["indexer"] == "test_indexer"
      assert event.metadata["download_client"] == "transmission"
    end

    test "download_initiated/4 includes media context when provided" do
      user_id = Ecto.UUID.generate()

      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Movie",
        type: "movie"
      }

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Test Download",
        indexer: "test_indexer",
        download_client: "transmission"
      }

      Events.download_initiated(download, :user, user_id, media_item: media_item)
      Process.sleep(100)

      [event] = Events.list_events(type: "download.initiated")
      assert event.metadata["media_item_id"] == media_item.id
      assert event.metadata["media_title"] == "Test Movie"
      assert event.metadata["media_type"] == "movie"
    end

    test "download_completed/2 creates correct event" do
      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Completed Download",
        download_client: "qbittorrent"
      }

      Events.download_completed(download)
      Process.sleep(100)

      [event] = Events.list_events(type: "download.completed")
      assert event.category == "downloads"
      assert event.actor_type == :system
      assert event.actor_id == "download_monitor"
      assert event.severity == :info
      assert event.metadata["title"] == "Completed Download"
    end

    test "download_failed/3 creates correct event" do
      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Failed Download",
        download_client: "transmission"
      }

      Events.download_failed(download, "Connection timeout")
      Process.sleep(100)

      [event] = Events.list_events(type: "download.failed")
      assert event.category == "downloads"
      assert event.severity == :error
      assert event.metadata["error_message"] == "Connection timeout"
      assert event.metadata["title"] == "Failed Download"
    end

    test "download_stalled/3 creates a warning event distinct from download.failed" do
      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Stalled Download",
        download_client: "transmission"
      }

      Events.download_stalled(download, "stalled after 60m without progress")
      Process.sleep(100)

      assert [] = Events.list_events(type: "download.failed")
      [event] = Events.list_events(type: "download.stalled")
      assert event.category == "downloads"
      assert event.actor_type == :system
      assert event.severity == :warning
      assert event.metadata["title"] == "Stalled Download"
    end

    test "download_unstalled/2 creates a recovery event referencing the download" do
      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Recovered Download",
        download_client: "transmission"
      }

      Events.download_unstalled(download)
      Process.sleep(100)

      [event] = Events.list_events(type: "download.unstalled")
      assert event.category == "downloads"
      assert event.severity == :info
      assert event.metadata["download_id"] == download.id
    end

    test "download_cancelled/3 creates correct event" do
      user_id = Ecto.UUID.generate()

      download = %Mydia.Downloads.Download{
        id: Ecto.UUID.generate(),
        title: "Cancelled Download",
        download_client: "transmission"
      }

      Events.download_cancelled(download, :user, user_id)
      Process.sleep(100)

      [event] = Events.list_events(type: "download.cancelled")
      assert event.category == "downloads"
      assert event.actor_type == :user
      assert event.metadata["title"] == "Cancelled Download"
    end

    test "job_executed/2 creates correct event" do
      Events.job_executed("metadata_refresh", %{
        "duration_ms" => 1500,
        "items_processed" => 10
      })

      Process.sleep(100)

      [event] = Events.list_events(type: "job.executed")
      assert event.category == "system"
      assert event.actor_type == :job
      assert event.actor_id == "metadata_refresh"
      assert event.metadata["job_name"] == "metadata_refresh"
      assert event.metadata["duration_ms"] == 1500
      assert event.metadata["items_processed"] == 10
    end

    test "job_failed/3 creates correct event" do
      Events.job_failed("metadata_refresh", "Connection timeout", %{
        "attempts" => 3
      })

      Process.sleep(100)

      [event] = Events.list_events(type: "job.failed")
      assert event.category == "system"
      assert event.severity == :error
      assert event.actor_type == :job
      assert event.metadata["error_message"] == "Connection timeout"
      assert event.metadata["attempts"] == 3
    end
  end

  describe "search event helpers" do
    test "search_completed/3 creates correct event for movie" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Movie",
        type: "movie"
      }

      metadata = %{
        "query" => "Test Movie 2024",
        "results_count" => 15,
        "selected_release" => "Test.Movie.2024.1080p.BluRay",
        "score" => 850,
        "breakdown" => %{"quality" => 200, "seeders" => 150}
      }

      Events.search_completed(media_item, metadata)
      Process.sleep(100)

      [event] = Events.list_events(type: "search.completed")
      assert event.category == "search"
      assert event.actor_type == :job
      assert event.actor_id == "movie_search"
      assert event.resource_type == "media_item"
      assert event.resource_id == media_item.id
      assert event.severity == :info
      assert event.metadata["title"] == "Test Movie"
      assert event.metadata["media_type"] == "movie"
      assert event.metadata["results_count"] == 15
      assert event.metadata["selected_release"] == "Test.Movie.2024.1080p.BluRay"
    end

    test "search_completed/3 creates correct event for TV episode" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Show",
        type: "tv_show"
      }

      episode = %Mydia.Media.Episode{
        id: Ecto.UUID.generate(),
        season_number: 1,
        episode_number: 5,
        media_item_id: media_item.id
      }

      metadata = %{
        "query" => "Test Show S01E05",
        "results_count" => 10
      }

      Events.search_completed(media_item, metadata, episode: episode)
      Process.sleep(100)

      [event] = Events.list_events(type: "search.completed")
      assert event.actor_id == "tv_show_search"
      assert event.resource_type == "episode"
      assert event.resource_id == episode.id
      assert event.metadata["season_number"] == 1
      assert event.metadata["episode_number"] == 5
    end

    test "search_no_results/3 creates correct event" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Rare Movie",
        type: "movie"
      }

      metadata = %{
        "query" => "Rare Movie 2024",
        "indexers_searched" => 3
      }

      Events.search_no_results(media_item, metadata)
      Process.sleep(100)

      [event] = Events.list_events(type: "search.no_results")
      assert event.category == "search"
      assert event.severity == :warning
      assert event.metadata["title"] == "Rare Movie"
      assert event.metadata["indexers_searched"] == 3
    end

    test "search_filtered_out/3 creates correct event with filter stats" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Show",
        type: "tv_show"
      }

      episode = %Mydia.Media.Episode{
        id: Ecto.UUID.generate(),
        season_number: 2,
        episode_number: 3,
        media_item_id: media_item.id
      }

      metadata = %{
        "query" => "Test Show S02E03",
        "results_count" => 10,
        "filter_stats" => %{
          "low_seeders" => 5,
          "wrong_quality" => 3,
          "blocked_tags" => 2
        },
        "top_rejections" => [
          %{"title" => "Some.Release", "reason" => "low_seeders", "value" => 1}
        ]
      }

      Events.search_filtered_out(media_item, metadata, episode: episode)
      Process.sleep(100)

      [event] = Events.list_events(type: "search.filtered_out")
      assert event.category == "search"
      assert event.severity == :warning
      assert event.metadata["results_count"] == 10
      assert event.metadata["filter_stats"]["low_seeders"] == 5
      assert event.metadata["season_number"] == 2
      assert event.metadata["episode_number"] == 3
    end

    test "search_error/4 creates correct event" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Movie",
        type: "movie"
      }

      Events.search_error(media_item, "Connection timeout", %{
        "query" => "Test Movie 2024"
      })

      Process.sleep(100)

      [event] = Events.list_events(type: "search.error")
      assert event.category == "search"
      assert event.severity == :error
      assert event.metadata["error_message"] == "Connection timeout"
      assert event.metadata["query"] == "Test Movie 2024"
    end

    test "search_started/3 creates correct event" do
      media_item = %Mydia.Media.MediaItem{
        id: Ecto.UUID.generate(),
        title: "Test Show",
        type: "tv_show"
      }

      metadata = %{
        "query" => "Test Show S01E01",
        "mode" => "specific"
      }

      Events.search_started(media_item, metadata)
      Process.sleep(100)

      [event] = Events.list_events(type: "search.started")
      assert event.category == "search"
      assert event.severity == :info
      assert event.actor_id == "tv_show_search"
      assert event.metadata["mode"] == "specific"
    end
  end

  describe "download_failed/3 failure classification" do
    setup do
      media_item = Mydia.MediaFixtures.media_item_fixture()

      download =
        Mydia.DownloadsFixtures.download_fixture(%{
          media_item_id: media_item.id,
          download_client: "my-debrid"
        })

      %{download: download, media_item: media_item}
    end

    test "stores both keys when the caller supplies them", %{download: download} do
      Events.download_failed(download, "boom",
        failure_category: "missing_files",
        failure_detail: "missingFiles"
      )

      Process.sleep(100)

      assert [event] = Events.list_events(type: "download.failed")
      assert event.metadata["failure_category"] == "missing_files"
      assert event.metadata["failure_detail"] == "missingFiles"
    end

    test "omits the detail key when there is no detail", %{download: download} do
      Events.download_failed(download, "boom", failure_category: "no_peers")

      Process.sleep(100)

      assert [event] = Events.list_events(type: "download.failed")
      assert event.metadata["failure_category"] == "no_peers"
      refute Map.has_key?(event.metadata, "failure_detail")
    end

    test "omits both keys entirely when the caller supplies neither", %{download: download} do
      Events.download_failed(download, "boom")

      Process.sleep(100)

      assert [event] = Events.list_events(type: "download.failed")
      refute Map.has_key?(event.metadata, "failure_category")
      refute Map.has_key?(event.metadata, "failure_detail")
      assert event.metadata["error_message"] == "boom"
    end
  end

  describe "Event.changeset/2 type registration" do
    test "accepts a registered type" do
      changeset =
        Event.changeset(%Event{}, %{
          category: "downloads",
          type: "download.stalled",
          actor_type: :system,
          actor_id: "download_monitor"
        })

      assert changeset.valid?
    end

    test "rejects a well-formed but unregistered type" do
      changeset = Event.changeset(%Event{}, %{category: "downloads", type: "download.invented"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).type
    end

    test "still reports the format error for a malformed type" do
      changeset = Event.changeset(%Event{}, %{category: "downloads", type: "nodot"})

      refute changeset.valid?
      assert "must be format: category.action" in errors_on(changeset).type
    end
  end

  describe "list_events/1 exclude_types" do
    setup do
      {:ok, kept} =
        Events.create_event(%{
          category: "plugin",
          type: "plugin.update_available",
          actor_type: :system,
          actor_id: "tmdb-art",
          metadata: %{"slug" => "tmdb-art"}
        })

      {:ok, excluded} =
        Events.create_event(%{
          category: "plugin",
          type: "plugin.http_request",
          actor_type: :system,
          actor_id: "tmdb-art",
          metadata: %{"slug" => "tmdb-art"}
        })

      %{kept: kept, excluded: excluded}
    end

    test "omits the excluded types", %{kept: kept} do
      ids =
        [exclude_types: ["plugin.http_request"]]
        |> Events.list_events()
        |> Enum.map(& &1.id)

      assert kept.id in ids
      assert length(ids) == 1
    end

    test "an empty list excludes nothing" do
      assert length(Events.list_events(exclude_types: [])) == 2
    end

    test "omitting the option excludes nothing" do
      assert length(Events.list_events()) == 2
    end
  end
end
