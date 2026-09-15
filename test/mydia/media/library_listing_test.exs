defmodule Mydia.Media.LibraryListingTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.LibraryListing
  alias Mydia.Media.LibraryRow
  alias Mydia.Media.MediaItem

  setup do
    %{user: user_fixture()}
  end

  describe "row/2 agrees with the preloaded computation" do
    test "a movie with nothing on disk", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Salt Meridian"})

      assert_parity(movie, user)
    end

    test "a movie with a version file", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Copper Wake"})
      media_file_fixture(%{media_item_id: movie.id, resolution: "2160p", size: 5_000})

      row = assert_parity(movie, user)
      assert row.status.state == :downloaded
      assert row.resolutions == ["2160p"]
    end

    test "a movie whose only files are an extra and a trashed version", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Lantern Quay"})
      media_file_fixture(%{media_item_id: movie.id, extra_kind: :trailer})
      media_file_fixture(%{media_item_id: movie.id, trashed_at: now()})

      row = assert_parity(movie, user)
      assert row.status.state == :missing
      assert row.resolutions == []
      assert row.total_size == 0
    end

    test "a movie file with no resolution or size", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Blank Ledger"})
      media_file_fixture(%{media_item_id: movie.id, resolution: nil, size: nil})

      row = assert_parity(movie, user)
      assert row.status.state == :downloaded
    end

    test "a movie with an active download", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Northbound Almanac"})
      download_fixture(%{media_item_id: movie.id})

      assert assert_parity(movie, user).status.state == :downloading
    end

    test "a movie whose downloads errored or completed", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Quiet Foundry"})
      download_fixture(%{media_item_id: movie.id, error_message: "tracker unreachable"})
      download_fixture(%{media_item_id: movie.id, completed_at: now()})

      assert assert_parity(movie, user).status.state == :missing
    end

    test "a show with no episodes", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Pending Harbor"})

      row = assert_parity(show, user)
      assert row.episode_count == 0
    end

    test "a multi-episode file counts for every episode it covers", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Twin Current"})
      first = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 9})
      second = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 10})
      file = media_file_fixture(%{episode_id: first.id, size: 700})
      {:ok, _} = Library.add_episode_links(file, [second.id])

      row = assert_parity(show, user)
      assert row.status.downloaded == 2
      # Preserved quirk: the shared file is counted once per episode.
      assert row.total_size == 1_400
    end

    test "a partly monitored show", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Half Signal"})
      watched = episode_fixture(%{media_item_id: show.id, monitored: true})
      episode_fixture(%{media_item_id: show.id, monitored: true})
      ignored = episode_fixture(%{media_item_id: show.id, monitored: false})
      media_file_fixture(%{episode_id: watched.id})
      media_file_fixture(%{episode_id: ignored.id})

      row = assert_parity(show, user)
      assert {row.status.downloaded, row.status.total} == {1, 2}
    end

    test "a monitored show with no monitored episodes", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Muted Relay", monitored: true})
      episode = episode_fixture(%{media_item_id: show.id, monitored: false})
      episode_fixture(%{media_item_id: show.id, monitored: false})
      media_file_fixture(%{episode_id: episode.id})

      row = assert_parity(show, user)
      refute row.status.monitored
    end

    test "a show whose monitored episodes all air in the future", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Coming Tide"})
      future = Date.add(Date.utc_today(), 30)
      episode_fixture(%{media_item_id: show.id, monitored: true, air_date: future})
      episode_fixture(%{media_item_id: show.id, monitored: true, air_date: Date.add(future, 7)})
      episode_fixture(%{media_item_id: show.id, monitored: false, air_date: ~D[2020-02-02]})

      assert assert_parity(show, user).status.state == :upcoming
    end

    test "a show with an active episode download beside an errored one", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Busy Estuary"})
      active = episode_fixture(%{media_item_id: show.id})
      failed = episode_fixture(%{media_item_id: show.id})
      download_fixture(%{media_item_id: show.id, episode_id: active.id})

      download_fixture(%{
        media_item_id: show.id,
        episode_id: failed.id,
        error_message: "no seeders"
      })

      assert assert_parity(show, user).status.state == :downloading
    end

    test "a show with mixed resolutions and a missing air date", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Patchwork Coast"})
      past = episode_fixture(%{media_item_id: show.id, air_date: ~D[2021-05-01]})
      undated = episode_fixture(%{media_item_id: show.id, air_date: nil})
      episode_fixture(%{media_item_id: show.id, air_date: Date.add(Date.utc_today(), 12)})
      media_file_fixture(%{episode_id: past.id, resolution: "2160p"})
      media_file_fixture(%{episode_id: undated.id, resolution: "720p"})

      row = assert_parity(show, user)
      assert Enum.sort(row.resolutions) == ["2160p", "720p"]
      assert %Date{} = row.last_air_date
      assert %Date{} = row.next_air_date
    end
  end

  describe "row/2" do
    test "carries the viewer's playback progress and no one else's", %{user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Slow Beacon"})
      other = user_fixture()

      {:ok, mine} =
        Mydia.Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 600,
          duration_seconds: 6000
        })

      {:ok, _theirs} =
        Mydia.Playback.save_progress(other.id, [media_item_id: movie.id], %{
          position_seconds: 3000,
          duration_seconds: 6000
        })

      assert LibraryListing.row(movie.id, user.id).progress.id == mine.id
    end

    test "is nil for an item that does not exist", %{user: user} do
      assert LibraryListing.row(Ecto.UUID.generate(), user.id) == nil
    end

    test "issues the same number of queries however many episodes a show has", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Long Season"})
      add_episodes(show, 2)
      small = count_queries(fn -> LibraryListing.row(show.id, user.id) end)

      add_episodes(show, 38)
      large = count_queries(fn -> LibraryListing.row(show.id, user.id) end)

      assert small == large
    end
  end

  describe "page/1" do
    test "search matches title, original title, year and overview, ignoring case", %{
      user: user
    } do
      media_item_fixture(%{
        title: "Keeper's Ledger",
        year: 1994,
        metadata: %{"overview" => "A lighthouse keeper counts ships"}
      })

      media_item_fixture(%{title: "Glass Orchard", original_title: "Verger de Verre", year: 2011})

      assert titles(page(user, search: "KEEPER")) == ["Keeper's Ledger"]
      assert titles(page(user, search: "verger")) == ["Glass Orchard"]
      assert titles(page(user, search: "2011")) == ["Glass Orchard"]
      # The overview only exists in memory: this proves :search never reaches
      # Media.media_items_query/1, whose own :search filter matches titles only.
      assert titles(page(user, search: "lighthouse")) == ["Keeper's Ledger"]
      assert titles(page(user, search: nil)) |> length() == 2
    end

    test "the quality filter matches a show on any episode's resolution", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Sharp Coastline"})
      first = episode_fixture(%{media_item_id: show.id})
      second = episode_fixture(%{media_item_id: show.id})
      media_file_fixture(%{episode_id: first.id, resolution: "720p"})
      media_file_fixture(%{episode_id: second.id, resolution: "2160p"})
      media_item_fixture(%{type: "tv_show", title: "Blurry Inlet"})

      assert titles(page(user, type: "tv_show", quality: "2160p")) == ["Sharp Coastline"]
      assert titles(page(user, type: "tv_show", quality: "1080p")) == []
    end

    test "the progress filter matches the row's status", %{user: user} do
      owned = media_item_fixture(%{title: "Filed Away"})
      media_file_fixture(%{media_item_id: owned.id})
      media_item_fixture(%{title: "Still Wanted"})

      assert titles(page(user, progress: :downloaded)) == ["Filed Away"]
      assert titles(page(user, progress: :missing)) == ["Still Wanted"]
    end

    test "title, year and rating sorts", %{user: user} do
      media_item_fixture(%{title: "beta Signal", year: 2010, metadata: %{"vote_average" => 6.1}})
      media_item_fixture(%{title: "Alder Road", year: 1999, metadata: %{"vote_average" => 8.4}})
      media_item_fixture(%{title: "Cobalt Ferry", year: 2004, metadata: %{"vote_average" => 7.0}})

      by_title = ["Alder Road", "beta Signal", "Cobalt Ferry"]
      by_year = ["Alder Road", "Cobalt Ferry", "beta Signal"]
      by_rating = ["beta Signal", "Cobalt Ferry", "Alder Road"]

      assert titles(page(user, sort_by: "title_asc")) == by_title
      assert titles(page(user, sort_by: "title_desc")) == Enum.reverse(by_title)
      assert titles(page(user, sort_by: "year_asc")) == by_year
      assert titles(page(user, sort_by: "year_desc")) == Enum.reverse(by_year)
      assert titles(page(user, sort_by: "rating_asc")) == by_rating
      assert titles(page(user, sort_by: "rating_desc")) == Enum.reverse(by_rating)
      assert titles(page(user, sort_by: "not_a_sort")) == by_title
    end

    test "air date and episode count sorts", %{user: user} do
      today = Date.utc_today()
      media_item_fixture(%{type: "tv_show", title: "Quiet Meridian"})

      old = media_item_fixture(%{type: "tv_show", title: "Old Lantern"})
      episode_fixture(%{media_item_id: old.id, air_date: ~D[2019-03-01]})
      episode_fixture(%{media_item_id: old.id, air_date: Date.add(today, 100)})

      fresh = media_item_fixture(%{type: "tv_show", title: "Fresh Tideline"})
      episode_fixture(%{media_item_id: fresh.id, air_date: Date.add(today, -3)})
      episode_fixture(%{media_item_id: fresh.id, air_date: Date.add(today, 10)})
      episode_fixture(%{media_item_id: fresh.id, air_date: Date.add(today, 40)})

      sorted = fn sort_by -> titles(page(user, type: "tv_show", sort_by: sort_by)) end

      # Preserved quirk: "last aired" includes future episodes, so Old Lantern's
      # episode 100 days out outranks Fresh Tideline's 40 days out.
      assert sorted.("last_aired_desc") == ["Old Lantern", "Fresh Tideline", "Quiet Meridian"]
      assert sorted.("last_aired_asc") == ["Quiet Meridian", "Fresh Tideline", "Old Lantern"]
      assert sorted.("next_aired_asc") == ["Fresh Tideline", "Old Lantern", "Quiet Meridian"]
      assert sorted.("next_aired_desc") == ["Quiet Meridian", "Old Lantern", "Fresh Tideline"]
      assert sorted.("episode_count_asc") == ["Quiet Meridian", "Old Lantern", "Fresh Tideline"]
      assert sorted.("episode_count_desc") == ["Fresh Tideline", "Old Lantern", "Quiet Meridian"]
    end

    test "added sorts use when content arrived", %{user: user} do
      early = media_item_fixture(%{title: "Early Almanac"})

      %{media_item_id: early.id}
      |> media_file_fixture()
      |> backdate_media_file(~U[2024-01-01 00:00:00Z])

      late = media_item_fixture(%{title: "Late Almanac"})

      %{media_item_id: late.id}
      |> media_file_fixture()
      |> backdate_media_file(~U[2025-06-01 00:00:00Z])

      assert titles(page(user, sort_by: "added_desc")) == ["Late Almanac", "Early Almanac"]
      assert titles(page(user, sort_by: "added_asc")) == ["Early Almanac", "Late Almanac"]
    end

    test "offset, limit, has_more?, visible_ids and empty?", %{user: user} do
      items = for n <- 1..5, do: media_item_fixture(%{title: "Almanac #{n}"})

      first = page(user, sort_by: "title_asc", offset: 0, limit: 3)
      assert titles(first) == ["Almanac 1", "Almanac 2", "Almanac 3"]
      assert first.has_more?
      assert first.visible_ids == MapSet.new(items, & &1.id)
      refute first.empty?

      rest = page(user, sort_by: "title_asc", offset: 3, limit: 3)
      assert titles(rest) == ["Almanac 4", "Almanac 5"]
      refute rest.has_more?

      nothing = page(user, search: "matches no title at all")
      assert nothing.empty?
      assert nothing.visible_ids == MapSet.new()
    end

    test "exclude_categories drops claimed items and keeps unclassified ones", %{user: user} do
      categorized_media_item_fixture(%{title: "Claimed Comet", type: "tv_show"}, :anime_series)
      categorized_media_item_fixture(%{title: "Unsorted Drift", type: "tv_show"}, nil)

      assert titles(page(user, type: "tv_show", exclude_categories: [:anime_series])) == [
               "Unsorted Drift"
             ]
    end

    test "base_query scopes the listing", %{user: user} do
      media_item_fixture(%{title: "Kept Year", year: 2001})
      media_item_fixture(%{title: "Other Year", year: 2002})

      base_query = from(m in MediaItem, where: m.year == 2001)

      assert titles(page(user, base_query: base_query)) == ["Kept Year"]
    end

    test "issues the same number of queries however large the library is", %{user: user} do
      show = media_item_fixture(%{type: "tv_show", title: "Growing Archive"})
      add_episodes(show, 2)
      small = count_queries(fn -> page(user, type: "tv_show") end)

      add_episodes(show, 38)
      media_item_fixture(%{type: "tv_show", title: "Second Archive"})
      large = count_queries(fn -> page(user, type: "tv_show") end)

      assert small == large
    end
  end

  # What the listing computed before LibraryListing existed: a fully preloaded
  # item run through get_media_status/1 and the old MediaLive.Index helpers,
  # with files gathered the way MediaFileHelpers.all_media_files/1 does.
  defp expected(item_id) do
    versions = MediaFile.versions()

    item =
      Media.get_media_item!(item_id,
        preload: [
          :downloads,
          media_files: versions,
          episodes: [media_files: versions, downloads: []]
        ]
      )

    files = item.media_files ++ Enum.flat_map(item.episodes, & &1.media_files)
    air_dates = item.episodes |> Enum.map(& &1.air_date) |> Enum.reject(&is_nil/1)
    today = Date.utc_today()
    series? = item.type == "tv_show"

    %{
      status: Media.get_media_status(item),
      resolutions:
        files |> Enum.map(& &1.resolution) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
      total_size: files |> Enum.map(& &1.size) |> Enum.reject(&is_nil/1) |> Enum.sum(),
      episode_count: if(series?, do: length(item.episodes), else: 0),
      last_air_date: if(series?, do: Enum.max(air_dates, Date, fn -> nil end)),
      next_air_date:
        if(series?,
          do:
            air_dates
            |> Enum.filter(&(Date.compare(&1, today) == :gt))
            |> Enum.min(Date, fn -> nil end)
        )
    }
  end

  defp page(user, opts) do
    LibraryListing.page(Keyword.merge([user_id: user.id, limit: 50], opts))
  end

  defp titles(%{rows: rows}), do: Enum.map(rows, & &1.item.title)

  defp actual(%LibraryRow{} = row) do
    %{
      status: row.status,
      resolutions: Enum.sort(row.resolutions),
      total_size: row.total_size,
      episode_count: row.episode_count,
      last_air_date: row.last_air_date,
      next_air_date: row.next_air_date
    }
  end

  defp assert_parity(item, user) do
    row = LibraryListing.row(item.id, user.id)
    assert %LibraryRow{} = row
    assert actual(row) == expected(item.id)
    row
  end

  defp add_episodes(show, count) do
    for _ <- 1..count do
      episode = episode_fixture(%{media_item_id: show.id})
      media_file_fixture(%{episode_id: episode.id})
      download_fixture(%{media_item_id: show.id, episode_id: episode.id})
    end
  end

  defp count_queries(fun) do
    test_pid = self()
    counter = :counters.new(1, [])
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:mydia, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
      :counters.get(counter, 1)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
