defmodule MydiaWeb.MediaLive.Show.ExistingFilesTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias MydiaWeb.MediaLive.Show.ExistingFiles

  defp file(name, attrs \\ %{}) do
    struct!(
      MediaFile,
      Map.merge(
        %{
          relative_path: "Glass Harbor (2019)/#{name}",
          resolution: "1080p",
          codec: "hevc",
          size: 4_000_000_000
        },
        attrs
      )
    )
  end

  defp episode(id, season, files, air_date \\ ~D[2020-01-01]) do
    %Episode{
      id: id,
      season_number: season,
      episode_number: 1,
      air_date: air_date,
      media_files: files
    }
  end

  describe "movie" do
    test "names the first version file and counts the rest" do
      item = %MediaItem{
        type: "movie",
        media_files: [
          file("Glass.Harbor.2019.1080p.WEB-DL.x265.mkv"),
          file("Glass.Harbor.2019.2160p.REMUX.mkv", %{resolution: "2160p"})
        ],
        episodes: []
      }

      assert %ExistingFiles{
               kind: :file,
               filename: "Glass.Harbor.2019.1080p.WEB-DL.x265.mkv",
               extra_count: 1,
               resolution: "1080p",
               codec: "HEVC",
               size: 4_000_000_000
             } = ExistingFiles.summarize(item, %{type: :media_item})
    end

    test "extras are not versions" do
      item = %MediaItem{
        type: "movie",
        media_files: [file("Glass.Harbor.Trailer.mkv", %{extra_kind: :trailer})],
        episodes: []
      }

      assert ExistingFiles.summarize(item, %{type: :media_item}) == nil
    end

    test "nothing on disk is nil" do
      assert ExistingFiles.summarize(
               %MediaItem{type: "movie", media_files: [], episodes: []},
               %{type: :media_item}
             ) == nil
    end
  end

  describe "episode" do
    test "uses that episode's file" do
      item = %MediaItem{
        type: "tv_show",
        media_files: [],
        episodes: [
          episode("e1", 1, [
            file("Tidewater.S01E01.720p.HDTV.x264.mkv", %{resolution: "720p", codec: "h264"})
          ]),
          episode("e2", 1, [])
        ]
      }

      assert %ExistingFiles{
               kind: :file,
               filename: "Tidewater.S01E01.720p.HDTV.x264.mkv",
               codec: "AVC"
             } = ExistingFiles.summarize(item, %{type: :episode, episode_id: "e1"})

      assert ExistingFiles.summarize(item, %{type: :episode, episode_id: "e2"}) == nil
    end
  end

  describe "season" do
    test "counts aired episodes and reports the dominant quality" do
      item = %MediaItem{
        type: "tv_show",
        media_files: [],
        episodes: [
          episode("e1", 1, [file("Tidewater.S01E01.1080p.WEB-DL.x265.mkv")]),
          episode("e2", 1, [file("Tidewater.S01E02.1080p.WEB-DL.x265.mkv")]),
          episode("e3", 1, [
            file("Tidewater.S01E03.720p.HDTV.x264.mkv", %{resolution: "720p", codec: "h264"})
          ]),
          episode("e4", 1, []),
          episode("e5", 1, [], Date.add(Date.utc_today(), 30)),
          episode("e6", 2, [file("Tidewater.S02E01.2160p.mkv")])
        ]
      }

      assert %ExistingFiles{
               kind: :season,
               on_disk: 3,
               total: 4,
               resolution: "1080p",
               source: "WEB-DL",
               codec: "HEVC"
             } = ExistingFiles.summarize(item, %{type: :season, season_number: 1})
    end

    test "a season with nothing on disk is nil" do
      item = %MediaItem{type: "tv_show", media_files: [], episodes: [episode("e1", 3, [])]}
      assert ExistingFiles.summarize(item, %{type: :season, season_number: 3}) == nil
    end
  end

  test "a whole-show search shows nothing" do
    item = %MediaItem{
      type: "tv_show",
      media_files: [],
      episodes: [episode("e1", 1, [file("x.mkv")])]
    }

    assert ExistingFiles.summarize(item, %{type: :media_item}) == nil
  end
end
