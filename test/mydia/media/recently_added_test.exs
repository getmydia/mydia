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

    test "a library-sized id list is chunked rather than raising on a bind-parameter ceiling" do
      # Enough synthetic ids to force multiple chunks (well past @id_chunk_size)
      # without paying for thousands of real media items and files. None of
      # these match a real row, so the correct answer is an empty map; the
      # point is that the query executes at all.
      ids = for _ <- 1..5000, do: Ecto.UUID.generate()

      assert RecentlyAdded.added_at_map(ids: ids) == %{}
    end

    test "chunking still returns real matches scattered across chunk boundaries" do
      movie_a = media_item_fixture(%{type: "movie"})
      movie_b = media_item_fixture(%{type: "movie"})

      backdate_media_file(media_file_fixture(%{media_item_id: movie_a.id}), @yesterday)
      backdate_media_file(media_file_fixture(%{media_item_id: movie_b.id}), @last_week)

      noise_ids = for _ <- 1..5000, do: Ecto.UUID.generate()
      ids = [movie_a.id | noise_ids] ++ [movie_b.id]

      assert RecentlyAdded.added_at_map(ids: ids) == %{
               movie_a.id => @yesterday,
               movie_b.id => @last_week
             }
    end
  end

  describe "list_recent/1" do
    setup do
      %{since: @last_week}
    end

    test "returns a long-owned show whose episode arrived inside the window", %{since: since} do
      show = media_item_fixture(%{type: "tv_show", title: "The Bear"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 4, episode_number: 2})
      backdate_media_file(media_file_fixture(%{episode_id: episode.id}), @yesterday)

      assert [entry] = RecentlyAdded.list_recent(since: since)
      assert entry.media_item.id == show.id
      assert entry.content_added_at == @yesterday
      assert entry.new_episode_count == 1
      assert entry.latest_episode.id == episode.id
    end

    test "excludes items whose content predates the window", %{since: since} do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})
      backdate_media_file(media_file_fixture(%{episode_id: episode.id}), @long_ago)

      assert RecentlyAdded.list_recent(since: since) == []
    end

    test "counts only episodes first filled inside the window", %{since: since} do
      show = media_item_fixture(%{type: "tv_show"})
      old_ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      new_ep = episode_fixture(%{media_item_id: show.id, season_number: 4, episode_number: 2})

      backdate_media_file(media_file_fixture(%{episode_id: old_ep.id}), @long_ago)
      backdate_media_file(media_file_fixture(%{episode_id: new_ep.id}), @yesterday)

      assert [entry] = RecentlyAdded.list_recent(since: since)
      assert entry.new_episode_count == 1
      assert entry.latest_episode.id == new_ep.id
    end

    test "a movie reports nil context rather than a count of one", %{since: since} do
      movie = media_item_fixture(%{type: "movie"})
      backdate_media_file(media_file_fixture(%{media_item_id: movie.id}), @yesterday)

      assert [entry] = RecentlyAdded.list_recent(since: since)
      assert entry.media_item.id == movie.id
      assert entry.new_episode_count == nil
      assert entry.latest_episode == nil
    end

    test "a show whose newest slot is unmatched files has a count but no episode",
         %{since: since} do
      show = media_item_fixture(%{type: "tv_show"})
      backdate_media_file(media_file_fixture(%{media_item_id: show.id}), @yesterday)

      assert [entry] = RecentlyAdded.list_recent(since: since)
      assert entry.new_episode_count == 1
      assert entry.latest_episode == nil
    end

    test "a show reports no latest episode when its newest slot is unmatched files",
         %{since: since} do
      show = media_item_fixture(%{type: "tv_show"})
      old_ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      backdate_media_file(media_file_fixture(%{episode_id: old_ep.id}), @long_ago)
      backdate_media_file(media_file_fixture(%{media_item_id: show.id}), @yesterday)

      assert [entry] = RecentlyAdded.list_recent(since: since)
      assert entry.new_episode_count == 1
      assert entry.latest_episode == nil
    end

    test "orders newest first", %{since: since} do
      older = media_item_fixture(%{type: "movie", title: "Older"})
      newer = media_item_fixture(%{type: "movie", title: "Newer"})

      backdate_media_file(media_file_fixture(%{media_item_id: older.id}), @last_week)
      backdate_media_file(media_file_fixture(%{media_item_id: newer.id}), @yesterday)

      assert [first, second] = RecentlyAdded.list_recent(since: since)
      assert first.media_item.id == newer.id
      assert second.media_item.id == older.id
    end

    test "filters by type", %{since: since} do
      movie = media_item_fixture(%{type: "movie"})
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      backdate_media_file(media_file_fixture(%{media_item_id: movie.id}), @yesterday)
      backdate_media_file(media_file_fixture(%{episode_id: episode.id}), @yesterday)

      assert [entry] = RecentlyAdded.list_recent(since: since, types: ["movie"])
      assert entry.media_item.id == movie.id
    end

    test "honors the limit", %{since: since} do
      for _ <- 1..3 do
        movie = media_item_fixture(%{type: "movie"})
        backdate_media_file(media_file_fixture(%{media_item_id: movie.id}), @yesterday)
      end

      assert length(RecentlyAdded.list_recent(since: since, limit: 2)) == 2
    end
  end
end
