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
