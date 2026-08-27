defmodule MydiaWeb.MediaLive.Show.LoadersSubtitleTracksTest do
  # `media_item.media_files` is always empty for a TV show: a MediaFile
  # belongs to either media_item_id or episode_id, never both. Mirrors
  # test/mydia_web/live/media_live/show/loaders_transcode_jobs_test.exs,
  # which already covers the identical movie/TV split for transcode jobs.
  use Mydia.DataCase

  alias Mydia.Subtitles.Subtitle
  alias MydiaWeb.MediaLive.Show.Loaders

  describe "load_media_file_subtitle_tracks/1" do
    setup do
      library = insert(:library_path, type: :series)
      show = insert(:tv_show)
      episode = insert(:episode, media_item: show)

      media_file =
        insert(:media_file,
          episode: episode,
          library_path: library,
          relative_path: "s01e01.mkv"
        )

      # Preloads media_files: :library_path, unlike
      # loaders_transcode_jobs_test.exs's identical-looking setup: that test
      # never touches MediaFile.absolute_path/1, but list_subtitle_tracks/2
      # does (to look for embedded streams when no metadata capture exists),
      # and an unloaded association there only logs a warning rather than
      # failing the test, so leaving it out would hide the gap instead of
      # catching it.
      media_item = Repo.preload(show, [:media_files, episodes: [media_files: :library_path]])

      %{media_item: media_item, media_file: media_file}
    end

    test "includes tracks for an episode's media file, not just the item's own", %{
      media_item: media_item,
      media_file: media_file
    } do
      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: "loader-episode-hash",
          file_path: "/tmp/loader-episode-hash.srt",
          format: "srt"
        })
        |> Repo.insert()

      file_id = media_file.id

      assert %{^file_id => [track]} = Loaders.load_media_file_subtitle_tracks(media_item)
      assert track.track_id == subtitle.id
    end

    test "returns an empty map for an episode with no tracks, rather than skipping it", %{
      media_item: media_item,
      media_file: media_file
    } do
      file_id = media_file.id

      assert %{^file_id => []} = Loaders.load_media_file_subtitle_tracks(media_item)
    end

    test "attaches a recorded resync outcome to its track", %{
      media_item: media_item,
      media_file: media_file
    } do
      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: "loader-resync-hash",
          file_path: "/tmp/loader-resync-hash.srt",
          format: "srt"
        })
        |> Repo.insert()

      {:ok, _} =
        Mydia.Subtitles.TrackSettings.record_resync(
          media_file.id,
          subtitle.id,
          :low_confidence,
          0.09
        )

      file_id = media_file.id

      assert %{^file_id => [track]} = Loaders.load_media_file_subtitle_tracks(media_item)
      assert track.resync_state == "low_confidence"
    end

    test "leaves resync_state nil for a track that has never been attempted", %{
      media_item: media_item,
      media_file: media_file
    } do
      {:ok, _subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: "loader-no-resync-hash",
          file_path: "/tmp/loader-no-resync-hash.srt",
          format: "srt"
        })
        |> Repo.insert()

      file_id = media_file.id

      assert %{^file_id => [track]} = Loaders.load_media_file_subtitle_tracks(media_item)
      assert track.resync_state == nil
    end
  end
end
