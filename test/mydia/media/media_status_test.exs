defmodule Mydia.Media.MediaStatusTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Download
  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.{AvailabilityStatus, Episode, MediaItem}

  defp movie(attrs) do
    struct!(
      %MediaItem{type: "movie", monitored: true, media_files: [], downloads: []},
      attrs
    )
  end

  defp show(attrs) do
    struct!(%MediaItem{type: "tv_show", monitored: true, episodes: []}, attrs)
  end

  defp episode(attrs) do
    struct!(
      %Episode{monitored: true, air_date: ~D[2024-01-01], media_files: [], downloads: []},
      attrs
    )
  end

  defp active_download, do: %Download{completed_at: nil, error_message: nil}

  describe "get_media_status/1 for movies" do
    test "an unmonitored movie with no files is missing, not hidden" do
      status = Media.get_media_status(movie(monitored: false))

      assert %AvailabilityStatus{state: :missing, monitored: false, file_count: 0} = status
    end

    test "a monitored movie with no files is missing and monitored" do
      status = Media.get_media_status(movie(monitored: true))

      assert %AvailabilityStatus{state: :missing, monitored: true} = status
    end

    test "an unmonitored movie with a file is downloaded" do
      status = Media.get_media_status(movie(monitored: false, media_files: [%MediaFile{}]))

      assert %AvailabilityStatus{state: :downloaded, monitored: false, file_count: 1} = status
    end

    test "an unmonitored movie with an active download is downloading" do
      status =
        Media.get_media_status(movie(monitored: false, downloads: [active_download()]))

      assert %AvailabilityStatus{state: :downloading, monitored: false} = status
    end

    test "a completed download does not count as downloading" do
      finished = %Download{completed_at: ~U[2024-01-01 00:00:00Z], error_message: nil}
      status = Media.get_media_status(movie(downloads: [finished]))

      assert %AvailabilityStatus{state: :missing} = status
    end
  end

  describe "get_media_status/1 for series" do
    test "an unmonitored show with no episode files is missing over all episodes" do
      status =
        Media.get_media_status(
          show(monitored: false, episodes: [episode([]), episode([]), episode([])])
        )

      assert %AvailabilityStatus{
               state: :missing,
               monitored: false,
               downloaded: 0,
               total: 3
             } = status
    end

    test "an unmonitored show with some episode files is partial" do
      episodes = [episode(media_files: [%MediaFile{}]), episode([])]
      status = Media.get_media_status(show(monitored: false, episodes: episodes))

      assert %AvailabilityStatus{
               state: :partial,
               monitored: false,
               downloaded: 1,
               total: 2
             } = status
    end

    test "an unmonitored show with every episode downloaded is downloaded" do
      episodes = [episode(media_files: [%MediaFile{}]), episode(media_files: [%MediaFile{}])]
      status = Media.get_media_status(show(monitored: false, episodes: episodes))

      assert %AvailabilityStatus{state: :downloaded, monitored: false, downloaded: 2, total: 2} =
               status
    end

    test "a monitored show counts only its monitored episodes" do
      episodes = [
        episode(monitored: true, media_files: [%MediaFile{}]),
        episode(monitored: true),
        episode(monitored: false)
      ]

      status = Media.get_media_status(show(monitored: true, episodes: episodes))

      assert %AvailabilityStatus{
               state: :partial,
               monitored: true,
               downloaded: 1,
               total: 2
             } = status
    end

    test "a monitored show with every episode unmonitored reports real availability" do
      episodes = [
        episode(monitored: false, media_files: [%MediaFile{}]),
        episode(monitored: false),
        episode(monitored: false)
      ]

      status = Media.get_media_status(show(monitored: true, episodes: episodes))

      assert %AvailabilityStatus{
               state: :partial,
               monitored: false,
               downloaded: 1,
               total: 3
             } = status
    end

    test "a show whose in-scope episodes are all in the future is upcoming" do
      future = Date.add(Date.utc_today(), 30)
      episodes = [episode(air_date: future), episode(air_date: future)]

      status = Media.get_media_status(show(monitored: false, episodes: episodes))

      assert %AvailabilityStatus{state: :upcoming, monitored: false} = status
    end

    test "a show with an active episode download is downloading" do
      episodes = [episode(downloads: [active_download()]), episode([])]

      status = Media.get_media_status(show(monitored: false, episodes: episodes))

      assert %AvailabilityStatus{state: :downloading, monitored: false} = status
    end

    test "a show with no episodes at all is missing rather than downloaded" do
      status = Media.get_media_status(show(monitored: true, episodes: []))

      assert %AvailabilityStatus{state: :missing, downloaded: 0, total: 0} = status
    end

    # A freshly added show has no episodes until metadata lands. Nothing contradicts its
    # own monitored flag yet, so it must not render muted like the deliberately
    # all-unmonitored case below it.
    test "a monitored show awaiting episode metadata stays monitored" do
      status = Media.get_media_status(show(monitored: true, episodes: []))

      assert %AvailabilityStatus{monitored: true} = status
    end

    test "an unmonitored show with no episodes stays unmonitored" do
      status = Media.get_media_status(show(monitored: false, episodes: []))

      assert %AvailabilityStatus{monitored: false} = status
    end

    test "a monitored show with episodes but none monitored still mutes" do
      status =
        Media.get_media_status(show(monitored: true, episodes: [episode(monitored: false)]))

      assert %AvailabilityStatus{monitored: false} = status
    end
  end

  test "no code path returns the retired :not_monitored state" do
    items = [
      movie(monitored: false),
      movie(monitored: false, media_files: [%MediaFile{}]),
      show(monitored: false, episodes: [episode([])]),
      show(monitored: true, episodes: [episode(monitored: false)])
    ]

    for item <- items do
      refute Media.get_media_status(item).state == :not_monitored
    end
  end
end
