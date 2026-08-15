defmodule Mydia.Media.ExternalIdsTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Media.ExternalIds

  test "adds ids that no other row owns" do
    attrs = %{type: "tv_show", title: "New Show", tmdb_id: 1399}

    result = ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: "tt0944947"})

    assert result.tmdb_id == 1399
    assert result.tvdb_id == 121_361
  end

  test "never overwrites an id the caller already set" do
    attrs = %{type: "tv_show", title: "New Show", tvdb_id: 111}

    result = ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 222, imdb: nil})

    assert result.tvdb_id == 111
  end

  test "fills a key present but nil" do
    attrs = %{type: "tv_show", title: "New Show", tmdb_id: 1399, tvdb_id: nil}

    result = ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil})

    assert result.tvdb_id == 121_361
  end

  test "skips an id another row already owns, warns, persists an event, and leaves the rest of attrs intact" do
    incumbent = media_item_fixture(%{type: "tv_show", title: "Incumbent", tvdb_id: 121_361})

    attrs = %{type: "tv_show", title: "Challenger", tmdb_id: 1399}

    {result, log} =
      with_log(fn ->
        ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil},
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
      ExternalIds.put_free_ids(attrs, %{tmdb: nil, tvdb: 121_361, imdb: nil}, exclude_id: item.id)

    assert result.tvdb_id == 121_361
  end

  test "ignores nil external ids" do
    attrs = %{type: "tv_show", title: "New Show", tmdb_id: 1399}

    assert ExternalIds.put_free_ids(attrs, nil) == attrs
  end
end
