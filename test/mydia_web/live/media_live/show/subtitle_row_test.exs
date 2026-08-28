defmodule MydiaWeb.MediaLive.Show.SubtitleRowTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.MediaLive.Show.Components

  defp file do
    %MediaFile{
      id: "mf-1",
      path: nil,
      relative_path: "The Bear/S02E03.mkv",
      library_path: %LibraryPath{path: "/media/tv"},
      resolution: "1080p",
      codec: "h264",
      audio_codec: "aac",
      size: 3_100_000_000
    }
  end

  defp track(language) do
    %{
      track_id: 1,
      language: language,
      title: language,
      format: "srt",
      embedded: false,
      origin: :provider,
      deliverable: true,
      offset_ms: 0,
      resync_state: nil
    }
  end

  defp episode_row(tracks) do
    render_component(&Components.episode_file_row/1,
      file: file(),
      episode: %{id: "ep-1", title: "Sundae", season_number: 2, episode_number: 3},
      playback_enabled: false,
      transcode_jobs: [],
      subtitle_tracks: tracks
    )
  end

  describe "episode_file_row/1" do
    test "shows the subtitle button when the file has no tracks" do
      html = episode_row([])

      assert html =~ ~s|id="subtitle-open-mf-1"|
      assert html =~ ~s|phx-click="open_subtitle_manage"|
      assert html =~ ~s|phx-value-media-file-id="mf-1"|
    end

    test "renders no badge line when the file has no tracks" do
      refute episode_row([]) =~ "subtitle-badges-mf-1"
    end

    test "renders the badge line when the file has tracks" do
      html = episode_row([track("en")])

      assert html =~ "subtitle-badges-mf-1"
      assert html =~ "EN"
    end
  end

  describe "media_files_section/1" do
    test "shows the subtitle button for a file with no tracks" do
      html =
        render_component(&Components.media_files_section/1,
          media_item: %{media_files: [file()]},
          refreshing_file_metadata: false,
          transcode_jobs: %{},
          media_file_subtitle_tracks: %{}
        )

      # -file- suffixed: media_files_section/1 and episode_file_row/1 can
      # both render the same TV episode file at once (the flat list is
      # always on; the episode row only once expanded), so their ids must
      # never collide. See media_files_section/1's moduledoc.
      assert html =~ ~s|id="subtitle-open-file-mf-1"|
      refute html =~ "subtitle-badges-file-mf-1"
    end

    test "renders the badge line for a file with tracks" do
      html =
        render_component(&Components.media_files_section/1,
          media_item: %{media_files: [file()]},
          refreshing_file_metadata: false,
          transcode_jobs: %{},
          media_file_subtitle_tracks: %{"mf-1" => [track("es")]}
        )

      assert html =~ "subtitle-badges-file-mf-1"
      assert html =~ "ES"
    end

    test "renders the subtitle button for a TV file attached directly to the show, with no episode" do
      # media_item_id set, episode_id nil: Mydia.Jobs.MediaImport's catch-all
      # fallback creates exactly this shape when a TV download's episode
      # can't be resolved, and Mydia.Media.RecentlyAdded documents it as an
      # "unmatched file". season_components.ex only ever iterates
      # episode.media_files, so this file renders under no episode row --
      # media_files_section/1 is its only route to a subtitle affordance,
      # and it must not be gated out by item type.
      html =
        render_component(&Components.media_files_section/1,
          media_item: %{type: "tv_show", media_files: [file()], episodes: []},
          refreshing_file_metadata: false,
          transcode_jobs: %{},
          media_file_subtitle_tracks: %{}
        )

      assert html =~ ~s|id="subtitle-open-file-mf-1"|
      assert html =~ ~s|phx-click="open_subtitle_manage"|
      assert html =~ ~s|phx-value-media-file-id="mf-1"|
    end
  end
end
