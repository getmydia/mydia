defmodule Mydia.Media.ExternalIdsTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Media.ExternalIds

  test "adds ids that no other row owns" do
    attrs = %{type: "tv_show", title: "New Show", tmdb_id: 1399}

    result =
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: "tt0944947"},
        type: "tv_show"
      )

    assert result.tmdb_id == 1399
    assert result.tvdb_id == 121_361
  end

  test "never overwrites an id the caller already set" do
    attrs = %{type: "tv_show", title: "New Show", tvdb_id: 111}

    result = ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 222, imdb: nil}, type: "tv_show")

    assert result.tvdb_id == 111
  end

  test "fills a key present but nil" do
    attrs = %{type: "tv_show", title: "New Show", tmdb_id: 1399, tvdb_id: nil}

    result =
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil}, type: "tv_show")

    assert result.tvdb_id == 121_361
  end

  test "skips an id another row already owns, warns, persists an event, and leaves the rest of attrs intact" do
    incumbent = media_item_fixture(%{type: "tv_show", title: "Incumbent", tvdb_id: 121_361})

    attrs = %{type: "tv_show", title: "Challenger", tmdb_id: 1399}

    {result, log} =
      with_log(fn ->
        ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil},
          type: "tv_show",
          title: "Override Title"
        )
      end)

    assert log =~ "[ExternalIds] tvdb_id 121361 is already owned by another media item"

    refute Map.has_key?(result, :tvdb_id)
    assert result.tmdb_id == 1399
    assert result.title == "Challenger"

    assert [event] = Events.list_events(type: "media_item.duplicate_provider_id")
    assert event.category == "media"
    assert event.severity == :warning
    assert event.resource_type == "media_item"
    assert event.resource_id == incumbent.id
    assert event.metadata["provider"] == "tvdb"
    assert event.metadata["provider_id"] == 121_361
    assert event.metadata["existing_title"] == "Incumbent"
    # The explicit :title opt wins over attrs[:title] in what gets recorded.
    assert event.metadata["incoming_title"] == "Override Title"
  end

  test "does not treat a row's own id as a conflict" do
    item = media_item_fixture(%{type: "tv_show", title: "Self", tvdb_id: 121_361})

    attrs = %{type: "tv_show", title: "Self"}

    result =
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil},
        type: "tv_show",
        exclude_id: item.id
      )

    assert result.tvdb_id == 121_361
  end

  test "ignores nil external ids" do
    attrs = %{type: "tv_show", title: "New Show", tmdb_id: 1399}

    assert ExternalIds.put_free_ids(attrs, nil, type: "tv_show") == attrs
  end

  test "a cross-type owner is not a conflict" do
    media_item_fixture(%{type: "movie", title: "Incumbent Movie", year: 2014, tvdb_id: 121_361})

    attrs = %{type: "tv_show", title: "Challenger Show"}

    result =
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil}, type: "tv_show")

    assert result.tvdb_id == 121_361
    assert Events.list_events(type: "media_item.duplicate_provider_id") == []
  end

  test "raises without a :type option" do
    attrs = %{type: "tv_show", title: "New Show"}

    assert_raise ArgumentError, ~r/requires a :type option/, fn ->
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil})
    end
  end

  test "raises on an unrecognised :type option" do
    attrs = %{type: "tv_show", title: "New Show"}

    assert_raise ArgumentError, ~r/requires a :type option/, fn ->
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil}, type: "tvshow")
    end
  end

  test "raises without a :type option even when there are no external ids" do
    # The nil-external_ids clause validates too. A caller that forgot :type has
    # the same bug either way; letting it pass here hides it until the day a
    # provider actually cross-references something.
    assert_raise ArgumentError, ~r/requires a :type option/, fn ->
      ExternalIds.put_free_ids(%{type: "tv_show", title: "New Show"}, nil)
    end
  end

  describe "write/3" do
    test "retries once without the taken id, and reports the owner" do
      incumbent =
        media_item_fixture(%{type: "tv_show", title: "Incumbent", tvdb_id: 121_361})

      # The pre-flight read saw the id as free; by write time it is not. That is
      # the race, reproduced deterministically by skipping put_free_ids/3.
      attrs = %{type: "tv_show", title: "Challenger", tvdb_id: 121_361, tmdb_id: 1399}

      {result, log} =
        with_log(fn ->
          ExternalIds.write(attrs, [type: "tv_show"], fn attrs ->
            Mydia.Media.create_media_item(attrs, skip_episode_refresh: true)
          end)
        end)

      assert {:ok, created} = result
      assert log =~ "[ExternalIds] tvdb_id 121361 is already owned by another media item"

      assert is_nil(created.tvdb_id)
      assert created.tmdb_id == 1399
      assert created.title == "Challenger"

      assert [event] = Events.list_events(type: "media_item.duplicate_provider_id")
      assert event.resource_id == incumbent.id
      assert event.metadata["provider"] == "tvdb"
      assert event.metadata["provider_id"] == 121_361
    end

    test "drops both provider ids in one pass when both collide" do
      media_item_fixture(%{type: "tv_show", title: "Owner A", tvdb_id: 121_361})
      media_item_fixture(%{type: "tv_show", title: "Owner B", tmdb_id: 1399})

      attrs = %{type: "tv_show", title: "Challenger", tvdb_id: 121_361, tmdb_id: 1399}

      {result, _log} =
        with_log(fn ->
          ExternalIds.write(attrs, [type: "tv_show"], fn attrs ->
            Mydia.Media.create_media_item(attrs, skip_episode_refresh: true)
          end)
        end)

      assert {:ok, created} = result
      assert is_nil(created.tvdb_id)
      assert is_nil(created.tmdb_id)

      assert length(Events.list_events(type: "media_item.duplicate_provider_id")) == 2
    end

    test "passes an ordinary validation error through untouched" do
      # A movie with no year fails validate_year_for_movies/1, which is not a
      # constraint error and must not trigger a retry or an event.
      attrs = %{type: "movie", title: "No Year"}

      assert {:error, changeset} =
               ExternalIds.write(attrs, [type: "movie"], fn attrs ->
                 Mydia.Media.create_media_item(attrs)
               end)

      refute changeset.valid?
      assert Events.list_events(type: "media_item.duplicate_provider_id") == []
    end

    test "does not treat the row's own id as a conflict" do
      # tmdb_id is the id that actually collides (with "Owner", a different
      # row), so the first attempt genuinely hits the unique index and
      # write/3 genuinely retries. tvdb_id is item's own current value,
      # carried in the same attrs map: drop_taken/3 re-checks every present
      # provider id, not just the one the database reported, so without
      # exclude_id its live re-read of tvdb_id would find item itself and
      # wrongly report and drop the row's own id as a conflict with itself.
      item = media_item_fixture(%{type: "tv_show", title: "Self", tvdb_id: 121_361})
      owner = media_item_fixture(%{type: "tv_show", title: "Owner", tmdb_id: 1399})

      attrs = %{title: "Self Renamed", tmdb_id: 1399, tvdb_id: 121_361}

      {result, _log} =
        with_log(fn ->
          ExternalIds.write(attrs, [type: "tv_show", exclude_id: item.id], fn attrs ->
            Mydia.Media.update_media_item(item, attrs, reason: "test")
          end)
        end)

      assert {:ok, updated} = result
      assert updated.id == item.id
      assert updated.title == "Self Renamed"
      # tmdb_id lost the race to "Owner" and was dropped by the retry.
      assert is_nil(updated.tmdb_id)
      # tvdb_id is item's own id. exclude_id kept the live re-read from
      # treating item as its own conflict, so it survives untouched.
      assert updated.tvdb_id == 121_361

      # Only the genuine tmdb collision with "Owner" is reported; item's own
      # tvdb_id must not also show up as a bogus self-conflict.
      assert [event] = Events.list_events(type: "media_item.duplicate_provider_id")
      assert event.resource_id == owner.id
      assert event.metadata["provider"] == "tmdb"
    end

    test "returns the changeset when the retry collides again" do
      # A third writer claiming the other id between the two attempts. Simulated
      # by a closure that fails on tvdb first and on tmdb second, which is what
      # that interleaving looks like from write/3's side.
      media_item_fixture(%{type: "tv_show", title: "Owner A", tvdb_id: 121_361})
      media_item_fixture(%{type: "tv_show", title: "Owner B", tmdb_id: 1399})

      attrs = %{type: "tv_show", title: "Challenger", tvdb_id: 121_361}

      {result, _log} =
        with_log(fn ->
          ExternalIds.write(attrs, [type: "tv_show"], fn attrs ->
            # After the first pass drops :tvdb_id, put a taken :tmdb_id back, so
            # the retry hits a constraint the pre-pass could not have seen.
            attrs
            |> Map.put_new(:tmdb_id, 1399)
            |> Mydia.Media.create_media_item(skip_episode_refresh: true)
          end)
        end)

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{tmdb_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "an empty changes map after the drop writes nothing and emits no update event" do
      # Add.backfill_ids/2's shape: a changes map holding only provider ids. The
      # guard lives in the closure so the retry passes through it, otherwise
      # Media.update_media_item/3 emits a content-free media_item.updated event.
      item = media_item_fixture(%{type: "tv_show", title: "Incumbent"})
      media_item_fixture(%{type: "tv_show", title: "Owner", tvdb_id: 121_361})

      {result, _log} =
        with_log(fn ->
          ExternalIds.write(%{tvdb_id: 121_361}, [type: "tv_show", exclude_id: item.id], fn
            changes when changes == %{} -> {:ok, item}
            changes -> Mydia.Media.update_media_item(item, changes, reason: "test")
          end)
        end)

      assert {:ok, unchanged} = result
      assert unchanged.id == item.id
      assert is_nil(unchanged.tvdb_id)

      # `resource_id` is only honoured alongside `resource_type`
      # (Events.filter_by_resource/3 at lib/mydia/events.ex:320). Both are given.
      assert Events.list_events(
               type: "media_item.updated",
               resource_type: "media_item",
               resource_id: item.id
             ) == []
    end

    test "raises without a :type option" do
      assert_raise ArgumentError, ~r/requires a :type option/, fn ->
        ExternalIds.write(%{type: "movie", title: "X"}, [], fn attrs -> {:ok, attrs} end)
      end
    end
  end
end
