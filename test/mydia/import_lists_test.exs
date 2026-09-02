defmodule Mydia.ImportListsTest do
  # async: false because the metadata-relay tests below point
  # :mydia, :metadata_relay_url at a Bypass port, which is global application
  # env. DataCase forces async: false on SQLite anyway, so running async here
  # only ever leaked on PostgreSQL. See test/README.md.
  use Mydia.DataCase, async: false

  alias Mydia.ImportLists
  alias Mydia.ImportLists.{ImportList, ImportListItem}

  describe "import_lists" do
    @valid_attrs %{
      name: "TMDB Trending Movies",
      type: "tmdb_trending",
      media_type: "movie",
      enabled: true,
      sync_interval: 360,
      auto_add: false,
      monitored: true
    }

    @update_attrs %{
      name: "Updated List Name",
      sync_interval: 720,
      auto_add: true
    }

    @invalid_attrs %{name: nil, type: nil, media_type: nil}

    test "list_import_lists/0 returns all import lists" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)
      assert ImportLists.list_import_lists() == [import_list]
    end

    test "list_import_lists/1 filters by enabled status" do
      {:ok, enabled_list} = ImportLists.create_import_list(@valid_attrs)

      {:ok, disabled_list} =
        ImportLists.create_import_list(%{@valid_attrs | enabled: false, type: "tmdb_popular"})

      enabled_lists = ImportLists.list_import_lists(enabled: true)
      disabled_lists = ImportLists.list_import_lists(enabled: false)

      assert enabled_lists == [enabled_list]
      assert disabled_lists == [disabled_list]
    end

    test "list_import_lists/1 filters by media type" do
      {:ok, movie_list} = ImportLists.create_import_list(@valid_attrs)

      {:ok, tv_list} =
        ImportLists.create_import_list(%{
          @valid_attrs
          | media_type: "tv_show",
            type: "tmdb_popular"
        })

      movie_lists = ImportLists.list_import_lists_by_type("movie")
      tv_lists = ImportLists.list_import_lists_by_type("tv_show")

      assert movie_lists == [movie_list]
      assert tv_lists == [tv_list]
    end

    test "get_import_list!/1 returns the import list with given id" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)
      assert ImportLists.get_import_list!(import_list.id) == import_list
    end

    test "get_import_list!/1 raises when id doesn't exist" do
      assert_raise Ecto.NoResultsError, fn ->
        ImportLists.get_import_list!(Ecto.UUID.generate())
      end
    end

    test "get_import_list_by_type/2 returns the import list with given type and media_type" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)
      assert ImportLists.get_import_list_by_type("tmdb_trending", "movie") == import_list
      assert ImportLists.get_import_list_by_type("tmdb_popular", "movie") == nil
    end

    test "create_import_list/1 with valid data creates an import list" do
      assert {:ok, %ImportList{} = import_list} = ImportLists.create_import_list(@valid_attrs)
      assert import_list.name == "TMDB Trending Movies"
      assert import_list.type == "tmdb_trending"
      assert import_list.media_type == "movie"
      assert import_list.enabled == true
      assert import_list.sync_interval == 360
    end

    test "create_import_list/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = ImportLists.create_import_list(@invalid_attrs)
    end

    test "create_import_list/1 enforces unique constraint on type + media_type" do
      {:ok, _} = ImportLists.create_import_list(@valid_attrs)
      assert {:error, changeset} = ImportLists.create_import_list(@valid_attrs)
      assert "already exists for this media type" in errors_on(changeset).type
    end

    test "update_import_list/2 with valid data updates the import list" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)

      assert {:ok, %ImportList{} = updated} =
               ImportLists.update_import_list(import_list, @update_attrs)

      assert updated.name == "Updated List Name"
      assert updated.sync_interval == 720
      assert updated.auto_add == true
    end

    test "update_import_list/2 with invalid data returns error changeset" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)

      assert {:error, %Ecto.Changeset{}} =
               ImportLists.update_import_list(import_list, @invalid_attrs)

      assert import_list == ImportLists.get_import_list!(import_list.id)
    end

    test "delete_import_list/1 deletes the import list" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)
      assert {:ok, %ImportList{}} = ImportLists.delete_import_list(import_list)
      assert_raise Ecto.NoResultsError, fn -> ImportLists.get_import_list!(import_list.id) end
    end

    test "toggle_import_list/1 toggles enabled status" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)
      assert import_list.enabled == true

      {:ok, toggled} = ImportLists.toggle_import_list(import_list)
      assert toggled.enabled == false

      {:ok, toggled_again} = ImportLists.toggle_import_list(toggled)
      assert toggled_again.enabled == true
    end

    test "change_import_list/1 returns a changeset" do
      {:ok, import_list} = ImportLists.create_import_list(@valid_attrs)
      assert %Ecto.Changeset{} = ImportLists.change_import_list(import_list)
    end
  end

  describe "import_list_items" do
    setup do
      {:ok, import_list} =
        ImportLists.create_import_list(%{
          name: "Test List",
          type: "tmdb_trending",
          media_type: "movie"
        })

      %{import_list: import_list}
    end

    @valid_item_attrs %{
      tmdb_id: 123,
      title: "Test Movie",
      year: 2024,
      poster_path: "/test.jpg",
      discovered_at: ~U[2024-01-01 00:00:00Z]
    }

    test "list_import_list_items/2 returns all items for a list", %{import_list: import_list} do
      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.put(@valid_item_attrs, :import_list_id, import_list.id)
        )

      items = ImportLists.list_import_list_items(import_list)
      assert length(items) == 1
      assert hd(items).id == item.id
    end

    test "list_import_list_items/2 filters by status", %{import_list: import_list} do
      # Create a media item for the "added" item
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Added Movie",
          year: 2024
        })

      {:ok, pending} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{import_list_id: import_list.id, status: "pending"})
        )

      {:ok, _added} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{
            import_list_id: import_list.id,
            tmdb_id: 456,
            status: "added",
            media_item_id: media_item.id
          })
        )

      pending_items = ImportLists.list_import_list_items(import_list, status: "pending")
      assert length(pending_items) == 1
      assert hd(pending_items).id == pending.id
    end

    test "count_import_list_items/2 returns count by status", %{import_list: import_list} do
      # Create a media item for the "added" item
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Added Movie",
          year: 2024
        })

      {:ok, _} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{import_list_id: import_list.id, status: "pending"})
        )

      {:ok, _} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{
            import_list_id: import_list.id,
            tmdb_id: 456,
            status: "pending"
          })
        )

      {:ok, _} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{
            import_list_id: import_list.id,
            tmdb_id: 789,
            status: "added",
            media_item_id: media_item.id
          })
        )

      assert ImportLists.count_import_list_items(import_list) == 3
      assert ImportLists.count_import_list_items(import_list, "pending") == 2
      assert ImportLists.count_import_list_items(import_list, "added") == 1
    end

    test "get_pending_items/1 returns only pending items", %{import_list: import_list} do
      # Create a media item for the "added" item
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Added Movie",
          year: 2024
        })

      {:ok, pending} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{import_list_id: import_list.id, status: "pending"})
        )

      {:ok, _} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{
            import_list_id: import_list.id,
            tmdb_id: 456,
            status: "added",
            media_item_id: media_item.id
          })
        )

      pending_items = ImportLists.get_pending_items(import_list)
      assert length(pending_items) == 1
      assert hd(pending_items).id == pending.id
    end

    test "create_import_list_item/1 creates an item", %{import_list: import_list} do
      attrs = Map.put(@valid_item_attrs, :import_list_id, import_list.id)
      assert {:ok, %ImportListItem{} = item} = ImportLists.create_import_list_item(attrs)
      assert item.tmdb_id == 123
      assert item.title == "Test Movie"
      assert item.status == "pending"
    end

    test "upsert_import_list_item/1 reports :created for a brand new item", %{
      import_list: import_list
    } do
      attrs = Map.put(@valid_item_attrs, :import_list_id, import_list.id)

      assert {:ok, %ImportListItem{} = item, :created} =
               ImportLists.upsert_import_list_item(attrs)

      assert item.tmdb_id == 123
      assert item.title == "Test Movie"
    end

    test "upsert_import_list_item/1 updates existing item and reports :updated", %{
      import_list: import_list
    } do
      attrs = Map.put(@valid_item_attrs, :import_list_id, import_list.id)
      {:ok, original} = ImportLists.create_import_list_item(attrs)

      updated_attrs = Map.merge(attrs, %{title: "Updated Title", year: 2025})

      assert {:ok, updated, :updated} = ImportLists.upsert_import_list_item(updated_attrs)

      assert updated.id == original.id
      assert updated.title == "Updated Title"
      assert updated.year == 2025
    end

    test "upsert_import_list_item/1 only refreshes cached display fields on conflict, not status, skip_reason, media_item_id or discovered_at",
         %{import_list: import_list} do
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Already Added Movie", year: 2024})

      original_discovered_at = ~U[2024-01-01 00:00:00Z]

      attrs =
        Map.merge(@valid_item_attrs, %{
          import_list_id: import_list.id,
          discovered_at: original_discovered_at
        })

      {:ok, item} = ImportLists.create_import_list_item(attrs)
      {:ok, item} = ImportLists.mark_item_added(item, media_item.id)

      # A later sync re-discovering the same item must not clobber the
      # status, the link, or the original discovery time, only the cached
      # display fields.
      resync_attrs =
        Map.merge(attrs, %{
          title: "Refreshed Title",
          year: 2030,
          poster_path: "/refreshed.jpg",
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, updated, :updated} = ImportLists.upsert_import_list_item(resync_attrs)

      assert updated.id == item.id
      assert updated.title == "Refreshed Title"
      assert updated.year == 2030
      assert updated.poster_path == "/refreshed.jpg"
      assert updated.status == "added"
      assert updated.skip_reason == nil
      assert updated.media_item_id == media_item.id
      assert updated.discovered_at == original_discovered_at
    end

    test "upsert_import_list_item/1 never returns a unique-constraint error for the same key twice",
         %{import_list: import_list} do
      # The old implementation did a plain Repo.one lookup followed by a
      # separate insert or update; two callers racing the same
      # (import_list_id, tmdb_id) pair with no existing row yet could both
      # see `nil` and both attempt to insert, and the loser got back
      # {:error, changeset} from the unique constraint, which
      # process_items/2 silently dropped. The atomic on_conflict upsert has
      # no such window: every call for the same key succeeds and only one
      # row ever exists, insert or not.
      attrs = Map.put(@valid_item_attrs, :import_list_id, import_list.id)

      assert {:ok, _item, :created} = ImportLists.upsert_import_list_item(attrs)
      assert {:ok, _item, :updated} = ImportLists.upsert_import_list_item(attrs)
      assert {:ok, _item, :updated} = ImportLists.upsert_import_list_item(attrs)

      assert ImportLists.count_import_list_items(import_list) == 1
    end

    test "mark_item_added/2 updates status to added", %{import_list: import_list} do
      # Create a media item first for the foreign key
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Test Movie",
          year: 2024
        })

      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.put(@valid_item_attrs, :import_list_id, import_list.id)
        )

      {:ok, updated} = ImportLists.mark_item_added(item, media_item.id)

      assert updated.status == "added"
      assert updated.media_item_id == media_item.id
    end

    test "items marked as 'added' but with deleted media_item are treated as pending", %{
      import_list: import_list
    } do
      # Create a media item
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Test Movie",
          year: 2024
        })

      # Create an import list item and mark it as added
      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{
            import_list_id: import_list.id,
            status: "added",
            media_item_id: media_item.id
          })
        )

      # Verify item is counted as "added" when media_item exists
      assert ImportLists.count_import_list_items(import_list, "added") == 1
      assert ImportLists.count_import_list_items(import_list, "pending") == 0

      # Now delete the media item
      {:ok, _, _} = Mydia.Media.delete_media_item(media_item)

      # After deletion, the item should be treated as "pending" since media is gone
      assert ImportLists.count_import_list_items(import_list, "added") == 0
      assert ImportLists.count_import_list_items(import_list, "pending") == 1

      # Verify the item is returned by get_pending_items
      pending_items = ImportLists.get_pending_items(import_list)
      assert length(pending_items) == 1
      assert hd(pending_items).id == item.id
      # The in_library virtual field should be false
      assert hd(pending_items).in_library == false
    end

    test "mark_item_skipped/2 updates status to skipped with reason", %{import_list: import_list} do
      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.put(@valid_item_attrs, :import_list_id, import_list.id)
        )

      {:ok, updated} = ImportLists.mark_item_skipped(item, "Already in library")

      assert updated.status == "skipped"
      assert updated.skip_reason == "Already in library"
    end

    test "mark_item_failed/2 updates status to failed with reason", %{import_list: import_list} do
      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.put(@valid_item_attrs, :import_list_id, import_list.id)
        )

      {:ok, updated} = ImportLists.mark_item_failed(item, "Metadata fetch failed")

      assert updated.status == "failed"
      assert updated.skip_reason == "Metadata fetch failed"
    end

    test "reset_item/1 resets status to pending", %{import_list: import_list} do
      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.merge(@valid_item_attrs, %{import_list_id: import_list.id, status: "failed"})
        )

      {:ok, reset} = ImportLists.reset_item(item)

      assert reset.status == "pending"
      assert reset.skip_reason == nil
    end

    test "delete_import_list/1 cascades delete to items", %{import_list: import_list} do
      {:ok, item} =
        ImportLists.create_import_list_item(
          Map.put(@valid_item_attrs, :import_list_id, import_list.id)
        )

      {:ok, _} = ImportLists.delete_import_list(import_list)

      assert_raise Ecto.NoResultsError, fn ->
        ImportLists.get_import_list_item!(item.id)
      end
    end
  end

  describe "preset management" do
    test "available_preset_lists/0 returns all presets" do
      presets = ImportLists.available_preset_lists()
      refute Enum.empty?(presets)
      assert Enum.any?(presets, &(&1.id == :tmdb_trending_movies))
    end

    test "available_preset_lists_by_type/1 filters by media type" do
      movie_presets = ImportLists.available_preset_lists_by_type("movie")
      tv_presets = ImportLists.available_preset_lists_by_type("tv_show")

      assert Enum.all?(movie_presets, &(&1.media_type == "movie"))
      assert Enum.all?(tv_presets, &(&1.media_type == "tv_show"))
    end

    test "preset_configured?/1 returns false for unconfigured presets" do
      refute ImportLists.preset_configured?(:tmdb_trending_movies)
    end

    test "preset_configured?/1 returns true for configured presets" do
      {:ok, _} = ImportLists.create_from_preset(:tmdb_trending_movies)
      assert ImportLists.preset_configured?(:tmdb_trending_movies)
    end

    test "create_from_preset/1 creates a list with default settings" do
      {:ok, list} = ImportLists.create_from_preset(:tmdb_trending_movies)

      assert list.name == "TMDB Trending Movies"
      assert list.type == "tmdb_trending"
      assert list.media_type == "movie"
      assert list.enabled == true
      assert list.sync_interval == 360
      assert list.auto_add == false
    end

    test "create_from_preset/2 creates a list with custom settings" do
      {:ok, list} =
        ImportLists.create_from_preset(:tmdb_trending_movies,
          sync_interval: 720,
          auto_add: true
        )

      assert list.sync_interval == 720
      assert list.auto_add == true
    end

    test "create_from_preset/1 returns error for invalid preset" do
      assert {:error, :preset_not_found} = ImportLists.create_from_preset(:invalid_preset)
    end
  end

  describe "sync operations" do
    test "sync_due?/1 returns false for disabled lists" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: false
        })

      refute ImportLists.sync_due?(list)
    end

    test "sync_due?/1 returns true for lists never synced" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true
        })

      assert ImportLists.sync_due?(list)
    end

    test "sync_due?/1 returns true for lists past their interval" do
      past_time = DateTime.add(DateTime.utc_now(), -400, :minute)

      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 360,
          last_synced_at: past_time
        })

      assert ImportLists.sync_due?(list)
    end

    test "sync_due?/1 returns false for recently synced lists" do
      recent_time = DateTime.add(DateTime.utc_now(), -10, :minute)

      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 360,
          last_synced_at: recent_time
        })

      refute ImportLists.sync_due?(list)
    end

    test "mark_sync_success/1 updates last_synced_at and clears error" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          sync_error: "Previous error"
        })

      {:ok, updated} = ImportLists.mark_sync_success(list)

      assert updated.last_synced_at != nil
      assert updated.sync_error == nil
    end

    test "mark_sync_error/2 sets sync_error" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, updated} = ImportLists.mark_sync_error(list, "Connection failed")

      assert updated.sync_error == "Connection failed"
    end

    test "mark_sync_error/2 records the failure time and increments the consecutive failure count" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, once} = ImportLists.mark_sync_error(list, "Connection failed")
      assert once.config["consecutive_failures"] == 1
      assert is_binary(once.config["last_failed_at"])

      {:ok, twice} = ImportLists.mark_sync_error(once, "Connection failed again")
      assert twice.config["consecutive_failures"] == 2
    end

    test "mark_sync_success/1 resets the consecutive failure count" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, failed} = ImportLists.mark_sync_error(list, "Connection failed")
      assert failed.config["consecutive_failures"] == 1

      {:ok, recovered} = ImportLists.mark_sync_success(failed)

      refute Map.has_key?(recovered.config, "consecutive_failures")
      refute Map.has_key?(recovered.config, "last_failed_at")
    end

    test "mark_sync_error/2 preserves other config keys such as list_url" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "custom_url",
          media_type: "movie",
          list_url: "https://example.com/feed.json"
        })

      assert list.config["list_url"] == "https://example.com/feed.json"

      {:ok, failed} = ImportLists.mark_sync_error(list, "Connection failed")

      assert failed.config["list_url"] == "https://example.com/feed.json"
      assert failed.config["consecutive_failures"] == 1
    end

    test "sync_due?/1 is not immediately due again right after a failure, even for a list that has never synced" do
      # This is the exact scenario from the bug report: a misconfigured
      # list's very first sync fails. last_synced_at is only ever set by
      # mark_sync_success/1, so it stays nil forever, and before this fix
      # sync_due?/1's `last_synced_at: nil -> true` clause fired
      # unconditionally, ignoring the failure and every future one. A cron
      # tick every 15 minutes would re-enqueue this list forever.
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 60
        })

      {:ok, failed} = ImportLists.mark_sync_error(list, "boom")

      refute failed.last_synced_at
      refute ImportLists.sync_due?(failed)
    end

    test "sync_due?/1 is due again once the backoff delay from the first failure elapses" do
      old_failure = DateTime.add(DateTime.utc_now(), -70, :minute)

      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 60,
          config: %{
            "consecutive_failures" => 1,
            "last_failed_at" => DateTime.to_iso8601(old_failure)
          }
        })

      # One failure delays by exactly one interval (60 min); 70 min have passed.
      assert ImportLists.sync_due?(list)
    end

    test "sync_due?/1 is not yet due before the backoff delay from the first failure elapses" do
      recent_failure = DateTime.add(DateTime.utc_now(), -10, :minute)

      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 60,
          config: %{
            "consecutive_failures" => 1,
            "last_failed_at" => DateTime.to_iso8601(recent_failure)
          }
        })

      refute ImportLists.sync_due?(list)
    end

    test "sync_due?/1 doubles the delay for each additional consecutive failure" do
      # Two failures => 2x the interval (120 min). 90 minutes ago is past the
      # plain interval but still within the doubled delay.
      ninety_minutes_ago = DateTime.add(DateTime.utc_now(), -90, :minute)

      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 60,
          config: %{
            "consecutive_failures" => 2,
            "last_failed_at" => DateTime.to_iso8601(ninety_minutes_ago)
          }
        })

      refute ImportLists.sync_due?(list)
    end

    test "sync_due?/1 caps the backoff delay at 24 hours no matter how many failures" do
      within_cap = DateTime.add(DateTime.utc_now(), -23, :hour)
      beyond_cap = DateTime.add(DateTime.utc_now(), -25, :hour)

      {:ok, still_backing_off} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 60,
          config: %{
            "consecutive_failures" => 10,
            "last_failed_at" => DateTime.to_iso8601(within_cap)
          }
        })

      refute ImportLists.sync_due?(still_backing_off)

      {:ok, past_cap} =
        ImportLists.create_import_list(%{
          name: "Test 2",
          type: "tmdb_popular",
          media_type: "movie",
          enabled: true,
          sync_interval: 60,
          config: %{
            "consecutive_failures" => 10,
            "last_failed_at" => DateTime.to_iso8601(beyond_cap)
          }
        })

      assert ImportLists.sync_due?(past_cap)
    end

    test "sync_due?/1 survives a failure count large enough to overflow the backoff exponent" do
      # 2 ** 1024 overflows a float and raises ArithmeticError. A list that
      # keeps failing accrues about one failure a day once the 24h cap is
      # reached, and list_sync_due_lists/0 runs every list through sync_due?/1,
      # so an unclamped exponent would eventually stop syncing for every list.
      {:ok, absurdly_failed} =
        ImportLists.create_import_list(%{
          name: "Test",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true,
          sync_interval: 360,
          config: %{
            "consecutive_failures" => 5000,
            "last_failed_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -25, :hour))
          }
        })

      assert ImportLists.sync_due?(absurdly_failed)
      assert ImportLists.list_sync_due_lists() != []
    end

    test "list_sync_due_lists/0 returns only enabled lists due for sync" do
      # Create enabled list that needs sync (never synced)
      {:ok, due_list} =
        ImportLists.create_import_list(%{
          name: "Due List",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: true
        })

      # Create disabled list
      {:ok, _disabled} =
        ImportLists.create_import_list(%{
          name: "Disabled",
          type: "tmdb_popular",
          media_type: "movie",
          enabled: false
        })

      # Create recently synced list
      {:ok, _recent} =
        ImportLists.create_import_list(%{
          name: "Recent",
          type: "tmdb_trending",
          media_type: "tv_show",
          enabled: true,
          last_synced_at: DateTime.utc_now()
        })

      due_lists = ImportLists.list_sync_due_lists()
      assert length(due_lists) == 1
      assert hd(due_lists).id == due_list.id
    end
  end

  describe "check_duplicate/2" do
    test "matches an existing media item by tmdb_id" do
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Nebula Drift",
          year: 2022,
          tmdb_id: 555
        })

      assert {:duplicate, ^media_item} = ImportLists.check_duplicate(555, "movie")
    end

    test "returns :not_found when nothing matches and no title/year fallback is given" do
      assert :not_found = ImportLists.check_duplicate(9999, "movie")
    end

    test "falls back to a normalised title+year match when the tmdb_id lookup misses" do
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      assert {:duplicate, ^media_item} =
               ImportLists.check_duplicate(12_345, "movie", "  SILVERBACK STATION  ", 2019)
    end

    test "the title+year fallback picks one row when the library holds duplicates" do
      # Uniqueness is enforced on tmdb_id and tvdb_id, and NULLs do not
      # collide, so two scanned copies of one title can both sit here. This
      # used to raise Ecto.MultipleResultsError and take the sync job down.
      {:ok, first} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      {:ok, second} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      assert {:duplicate, matched} =
               ImportLists.check_duplicate(12_345, "movie", "Silverback Station", 2019)

      assert matched.id in [first.id, second.id]

      # The id is a UUID, so ordering by it is not insertion order, but it is
      # stable: the same call must keep returning the same row.
      assert {:duplicate, ^matched} =
               ImportLists.check_duplicate(12_345, "movie", "Silverback Station", 2019)
    end

    test "does not fall back when year is nil, even with a matching title" do
      Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      assert :not_found = ImportLists.check_duplicate(12_345, "movie", "Silverback Station", nil)
    end

    test "does not fall back when title is nil, even with a matching year" do
      Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      assert :not_found = ImportLists.check_duplicate(12_345, "movie", nil, 2019)
    end

    test "the title+year fallback ignores a row that already has a different tmdb_id" do
      # A row with its own tmdb_id is a genuinely different item, not a
      # scan-time match waiting to be linked, even if the title and year
      # happen to coincide.
      Mydia.Media.create_media_item(%{
        type: "movie",
        title: "Silverback Station",
        year: 2019,
        tmdb_id: 111
      })

      assert :not_found =
               ImportLists.check_duplicate(12_345, "movie", "Silverback Station", 2019)
    end

    test "the title+year fallback requires an exact year match" do
      Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      assert :not_found =
               ImportLists.check_duplicate(12_345, "movie", "Silverback Station", 2020)
    end

    test "the title+year fallback respects media type" do
      # skip_episode_refresh: true avoids Mydia.Media's post-insert TVDB
      # lookup for a tv_show with no provider id, which would otherwise
      # reach the network in this test.
      Mydia.Media.create_media_item(
        %{type: "tv_show", title: "Silverback Station", year: 2019},
        skip_episode_refresh: true
      )

      assert :not_found =
               ImportLists.check_duplicate(12_345, "movie", "Silverback Station", 2019)
    end
  end

  describe "add_item_to_library/2" do
    setup do
      {:ok, import_list} =
        ImportLists.create_import_list(%{
          name: "Test List",
          type: "tmdb_trending",
          media_type: "movie"
        })

      %{import_list: import_list}
    end

    test "links a duplicate to the existing media item in a single write", %{
      import_list: import_list
    } do
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Nebula Drift",
          year: 2022,
          tmdb_id: 777
        })

      {:ok, item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 777,
          title: "Nebula Drift",
          year: 2022,
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, ^media_item} = ImportLists.add_item_to_library(item, import_list)

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "added"
      assert reloaded.media_item_id == media_item.id
      # The wasted intermediate skip write (and its stale reason) must not
      # survive: the final row is honestly "added", not "skipped".
      assert reloaded.skip_reason == nil
    end

    test "links a duplicate found only via the title+year fallback", %{import_list: import_list} do
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      {:ok, item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 9001,
          title: "Silverback Station",
          year: 2019,
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, ^media_item} = ImportLists.add_item_to_library(item, import_list)
    end

    test "creates a new media item from relay metadata when nothing matches", %{
      import_list: import_list
    } do
      bypass = Bypass.open()
      previous_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      tmdb_id = 424_242

      Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        body = %{
          "id" => tmdb_id,
          "title" => "Halcyon Fields",
          "release_date" => "2024-03-15",
          "credits" => %{"cast" => [], "crew" => []},
          "external_ids" => %{"imdb_id" => "tt9999999"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: tmdb_id,
          title: "Halcyon Fields",
          year: 2024,
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, media_item} = ImportLists.add_item_to_library(item, import_list)
      assert media_item.title == "Halcyon Fields"

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "added"
      assert reloaded.media_item_id == media_item.id
    end

    test "marks the item failed when the metadata fetch fails", %{import_list: import_list} do
      bypass = Bypass.open()
      previous_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      tmdb_id = 424_243

      Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        Plug.Conn.resp(conn, 404, Jason.encode!(%{"error" => "not found"}))
      end)

      {:ok, item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: tmdb_id,
          title: "Missing Movie",
          year: 2024,
          discovered_at: DateTime.utc_now()
        })

      assert {:error, _reason} = ImportLists.add_item_to_library(item, import_list)

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "failed"
    end
  end

  describe "add_all_pending_to_library/1" do
    test "reports duplicates as added and totals stats across pending items" do
      {:ok, import_list} =
        ImportLists.create_import_list(%{
          name: "Test List",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, _media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Nebula Drift",
          year: 2022,
          tmdb_id: 777
        })

      {:ok, _duplicate_item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 777,
          title: "Nebula Drift",
          year: 2022,
          discovered_at: DateTime.utc_now()
        })

      bypass = Bypass.open()
      previous_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      Bypass.stub(bypass, "GET", "/tmdb/movies/424244", fn conn ->
        body = %{
          "id" => 424_244,
          "title" => "Halcyon Fields",
          "release_date" => "2024-03-15",
          "credits" => %{"cast" => [], "crew" => []}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, _new_item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 424_244,
          title: "Halcyon Fields",
          year: 2024,
          discovered_at: DateTime.utc_now()
        })

      Bypass.stub(bypass, "GET", "/tmdb/movies/424245", fn conn ->
        Plug.Conn.resp(conn, 404, Jason.encode!(%{"error" => "not found"}))
      end)

      {:ok, _failed_item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 424_245,
          title: "Missing Movie",
          year: 2024,
          discovered_at: DateTime.utc_now()
        })

      stats = ImportLists.add_all_pending_to_library(import_list)

      assert stats.added == 2
      assert stats.skipped == 0
      assert stats.failed == 1
    end
  end

  describe "mark_existing_items_in_library/1" do
    test "marks pending items already in the library as skipped and links them" do
      {:ok, import_list} =
        ImportLists.create_import_list(%{
          name: "Test List",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Nebula Drift",
          year: 2022,
          tmdb_id: 777
        })

      {:ok, matching_item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 777,
          title: "Nebula Drift",
          year: 2022,
          discovered_at: DateTime.utc_now()
        })

      {:ok, unmatched_item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 778,
          title: "Something Else",
          year: 2023,
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, 1} = ImportLists.mark_existing_items_in_library(import_list)

      reloaded_matching = ImportLists.get_import_list_item!(matching_item.id)
      assert reloaded_matching.status == "skipped"
      assert reloaded_matching.skip_reason == "Already in library"
      assert reloaded_matching.media_item_id == media_item.id

      reloaded_unmatched = ImportLists.get_import_list_item!(unmatched_item.id)
      assert reloaded_unmatched.status == "pending"
    end

    test "matches via the title+year fallback for library items with no tmdb_id" do
      {:ok, import_list} =
        ImportLists.create_import_list(%{
          name: "Test List",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, media_item} =
        Mydia.Media.create_media_item(%{type: "movie", title: "Silverback Station", year: 2019})

      {:ok, item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 9001,
          title: "Silverback Station",
          year: 2019,
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, 1} = ImportLists.mark_existing_items_in_library(import_list)

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "skipped"
      assert reloaded.media_item_id == media_item.id
    end

    test "returns 0 when no pending items match the library" do
      {:ok, import_list} =
        ImportLists.create_import_list(%{
          name: "Test List",
          type: "tmdb_trending",
          media_type: "movie"
        })

      {:ok, _item} =
        ImportLists.create_import_list_item(%{
          import_list_id: import_list.id,
          tmdb_id: 42,
          title: "Nothing Matches",
          year: 2025,
          discovered_at: DateTime.utc_now()
        })

      assert {:ok, 0} = ImportLists.mark_existing_items_in_library(import_list)
    end
  end
end
