defmodule MydiaWeb.MediaLive.Show.LoadersSubtitleTracksQueryCountTest do
  # Deliberately synchronous, and deliberately in its own file, for exactly the
  # reason spelled out at the top of
  # test/mydia/playback/on_deck_query_count_test.exs: the `:telemetry` handler
  # this test attaches is global to the VM, so running async alongside the
  # rest of the suite counts other modules' queries too.
  use Mydia.DataCase, async: false

  alias Mydia.MediaFixtures
  alias MydiaWeb.MediaLive.Show.Loaders

  # A TV show with `count` episodes, each with one media file. Mirrors
  # loaders_subtitle_tracks_test.exs's setup: `media_item.media_files` alone
  # is always empty for a TV show, and `Extractor.list_subtitle_tracks/2`
  # touches `MediaFile.absolute_path/1`, so `library_path` is preloaded too
  # even though this test only cares about the track-settings queries.
  defp show_with_files(count, title) do
    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: title})

    for n <- 1..count do
      episode =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 1,
          episode_number: n
        })

      MediaFixtures.media_file_fixture(%{episode_id: episode.id})
    end

    Repo.preload(show, [:media_files, episodes: [media_files: :library_path]])
  end

  # Counts only queries against `subtitle_track_settings`, not every query
  # `load_media_file_subtitle_tracks/1` issues. `Extractor.list_subtitle_tracks/2`
  # queries the `subtitles` table once per media file regardless of this
  # change (a separate, pre-existing N+1 outside this task's scope), so a
  # count of *all* repo queries would grow with file count even with the
  # batching fix in place and would never assert what this test is for.
  defp count_track_settings_queries(fun) do
    ref = make_ref()
    parent = self()

    handler = fn _event, _measurements, metadata, _config ->
      if metadata.source == "subtitle_track_settings" do
        send(parent, {ref, :query})
      end
    end

    :telemetry.attach(
      "loaders-subtitle-tracks-query-count-#{inspect(ref)}",
      [:mydia, :repo, :query],
      handler,
      nil
    )

    fun.()

    :telemetry.detach("loaders-subtitle-tracks-query-count-#{inspect(ref)}")

    drain = fn drain ->
      receive do
        {^ref, :query} -> 1 + drain.(drain)
      after
        0 -> 0
      end
    end

    drain.(drain)
  end

  describe "load_media_file_subtitle_tracks/1 query count" do
    test "issues a constant number of track-settings queries regardless of file count" do
      small_item = show_with_files(1, "Small Show")

      small =
        count_track_settings_queries(fn ->
          Loaders.load_media_file_subtitle_tracks(small_item)
        end)

      large_item = show_with_files(5, "Large Show")

      large =
        count_track_settings_queries(fn ->
          Loaders.load_media_file_subtitle_tracks(large_item)
        end)

      assert small == large,
             "expected a constant query count, got #{small} for 1 file and #{large} for 5 files"

      assert small == 2,
             "expected exactly 2 track-settings queries (offsets + resync states), got #{small}"
    end
  end
end
