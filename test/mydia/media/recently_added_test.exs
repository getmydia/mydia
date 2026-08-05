defmodule Mydia.Media.RecentlyAddedTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media.RecentlyAdded

  # Two years back, well outside any 30-day window.
  @long_ago ~U[2024-08-04 12:00:00Z]
  @yesterday ~U[2026-08-03 12:00:00Z]
  @last_week ~U[2026-07-28 12:00:00Z]

  describe "added_at_map/1" do
    test "a long-owned show reports its newest episode's arrival, not its own inserted_at" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 4, episode_number: 2})

      # Built the way production builds it: episode_id set, media_item_id NULL.
      # A fixture that set both would pass even against a query that only
      # groups on media_files.media_item_id, which is the defect this guards.
      file = media_file_fixture(%{episode_id: episode.id})
      assert file.media_item_id == nil
      backdate_media_file(file, @yesterday)

      assert RecentlyAdded.added_at_map() == %{show.id => @yesterday}
    end

    test "an upgrade does not move the timestamp" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      original = media_file_fixture(%{episode_id: episode.id})
      backdate_media_file(original, @long_ago)

      # The upgrade path inserts a second row on the same episode and trashes
      # the first. The slot's minimum must ignore the newer row.
      replacement = media_file_fixture(%{episode_id: episode.id})
      backdate_media_file(replacement, @yesterday)

      assert RecentlyAdded.added_at_map() == %{show.id => @long_ago}
    end

    test "a trashed original still counts as its episode's first file" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      original =
        media_file_fixture(%{
          episode_id: episode.id,
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      backdate_media_file(original, @long_ago)

      replacement = media_file_fixture(%{episode_id: episode.id})
      backdate_media_file(replacement, @yesterday)

      assert RecentlyAdded.added_at_map() == %{show.id => @long_ago}
    end

    test "a show reports the newest of its episodes" do
      show = media_item_fixture(%{type: "tv_show"})
      old_ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      new_ep = episode_fixture(%{media_item_id: show.id, season_number: 4, episode_number: 2})

      backdate_media_file(media_file_fixture(%{episode_id: old_ep.id}), @long_ago)
      backdate_media_file(media_file_fixture(%{episode_id: new_ep.id}), @yesterday)

      assert RecentlyAdded.added_at_map() == %{show.id => @yesterday}
    end

    test "a movie reports its file's arrival, not the item's inserted_at" do
      movie = media_item_fixture(%{type: "movie"})
      file = media_file_fixture(%{media_item_id: movie.id})
      backdate_media_file(file, @yesterday)

      assert RecentlyAdded.added_at_map() == %{movie.id => @yesterday}
    end

    test "an unmatched show file with no episode still resolves to its show" do
      show = media_item_fixture(%{type: "tv_show"})
      file = media_file_fixture(%{media_item_id: show.id})
      backdate_media_file(file, @yesterday)

      assert RecentlyAdded.added_at_map() == %{show.id => @yesterday}
    end

    test "an item with no files is absent" do
      media_item_fixture(%{type: "movie"})

      assert RecentlyAdded.added_at_map() == %{}
    end

    test "scopes to the given ids" do
      movie_a = media_item_fixture(%{type: "movie"})
      movie_b = media_item_fixture(%{type: "movie"})

      backdate_media_file(media_file_fixture(%{media_item_id: movie_a.id}), @yesterday)
      backdate_media_file(media_file_fixture(%{media_item_id: movie_b.id}), @last_week)

      assert RecentlyAdded.added_at_map(ids: [movie_a.id]) == %{movie_a.id => @yesterday}
    end

    test "an empty id list returns an empty map without querying everything" do
      movie = media_item_fixture(%{type: "movie"})
      backdate_media_file(media_file_fixture(%{media_item_id: movie.id}), @yesterday)

      assert RecentlyAdded.added_at_map(ids: []) == %{}
    end
  end
end
