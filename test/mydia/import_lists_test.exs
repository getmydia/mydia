defmodule Mydia.ImportListsTest do
  use Mydia.DataCase, async: true

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

    test "upsert_import_list_item/1 updates existing item", %{import_list: import_list} do
      attrs = Map.put(@valid_item_attrs, :import_list_id, import_list.id)
      {:ok, original} = ImportLists.create_import_list_item(attrs)

      updated_attrs = Map.merge(attrs, %{title: "Updated Title", year: 2025})
      {:ok, updated} = ImportLists.upsert_import_list_item(updated_attrs)

      assert updated.id == original.id
      assert updated.title == "Updated Title"
      assert updated.year == 2025
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
end
