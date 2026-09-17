defmodule MydiaWeb.MediaLive.Show.StorageSizeUiTest do
  use MydiaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias MydiaWeb.MediaLive.Show.{Components, SeasonComponents}

  describe "SeasonComponents.season_header/1" do
    test "renders season total size when episodes have media files with size" do
      episodes = [
        %Episode{
          id: 1,
          season_number: 1,
          air_date: ~D[2024-01-01],
          media_files: [
            %MediaFile{id: 10, size: 1_073_741_824}
          ]
        },
        %Episode{
          id: 2,
          season_number: 1,
          air_date: ~D[2024-01-08],
          media_files: [
            %MediaFile{id: 11, size: 536_870_912}
          ]
        }
      ]

      html =
        render_component(&SeasonComponents.season_header/1,
          season_number: 1,
          episodes: episodes,
          expanded?: false,
          auto_searching_season: nil,
          rescanning_season: nil,
          fetching_season_subtitles: nil
        )

      assert html =~ ~s{id="season-1-total-size"}
      assert html =~ "1.5 GB"
    end

    test "omits season total size when episodes have no media files" do
      episodes = [
        %Episode{
          id: 1,
          season_number: 1,
          air_date: ~D[2024-01-01],
          media_files: []
        }
      ]

      html =
        render_component(&SeasonComponents.season_header/1,
          season_number: 1,
          episodes: episodes,
          expanded?: false,
          auto_searching_season: nil,
          rescanning_season: nil,
          fetching_season_subtitles: nil
        )

      refute html =~ ~s{id="season-1-total-size"}
    end
  end

  describe "Components.episodes_section/1" do
    test "renders total show size in header" do
      show = %MediaItem{
        type: "tv_show",
        media_files: [],
        monitor_new_seasons: :all,
        episodes: [
          %Episode{
            id: 1,
            season_number: 1,
            monitored: true,
            media_files: [%MediaFile{id: 10, size: 2_147_483_648}]
          }
        ]
      }

      html =
        render_component(&Components.episodes_section/1,
          media_item: show,
          expanded_seasons: MapSet.new([1]),
          player_enabled: true,
          can_update_media: true
        )

      assert html =~ ~s{id="show-total-size"}
      assert html =~ "2.0 GB"
    end

    test "renders 0 B when show has no media files" do
      show = %MediaItem{
        type: "tv_show",
        media_files: [],
        monitor_new_seasons: :all,
        episodes: [
          %Episode{
            id: 1,
            season_number: 1,
            monitored: true,
            media_files: []
          }
        ]
      }

      html =
        render_component(&Components.episodes_section/1,
          media_item: show,
          expanded_seasons: MapSet.new([1]),
          player_enabled: true,
          can_update_media: true
        )

      assert html =~ ~s{id="show-total-size"}
      assert html =~ "0 B"
    end
  end

  describe "Components.hero_section/1" do
    test "renders Size on Disk for TV show" do
      show = %MediaItem{
        id: "show-1",
        title: "Test Show",
        type: "tv_show",
        monitored: true,
        quality_profile: nil,
        media_files: [],
        episodes: [
          %Episode{
            id: 1,
            season_number: 1,
            media_files: [%MediaFile{id: 10, size: 1_073_741_824}]
          }
        ]
      }

      html =
        render_component(&Components.hero_section/1,
          media_item: show,
          player_enabled: true,
          auto_searching: false,
          downloads_with_status: [],
          quality_profiles: []
        )

      assert html =~ ~s{id="hero-size-on-disk"}
      assert html =~ "Size on Disk"
      assert html =~ "1.0 GB"
    end

    test "renders Size on Disk for Movie" do
      movie = %MediaItem{
        id: "movie-1",
        title: "Test Movie",
        type: "movie",
        monitored: true,
        quality_profile: nil,
        media_files: [
          %MediaFile{id: 10, size: 3_221_225_472}
        ]
      }

      html =
        render_component(&Components.hero_section/1,
          media_item: movie,
          player_enabled: true,
          auto_searching: false,
          downloads_with_status: [],
          quality_profiles: []
        )

      assert html =~ ~s{id="hero-size-on-disk"}
      assert html =~ "Size on Disk"
      assert html =~ "3.0 GB"
    end

    test "renders 0 B when movie or show has no files" do
      movie = %MediaItem{
        id: "movie-empty",
        title: "Empty Movie",
        type: "movie",
        monitored: true,
        quality_profile: nil,
        media_files: []
      }

      html =
        render_component(&Components.hero_section/1,
          media_item: movie,
          player_enabled: true,
          auto_searching: false,
          downloads_with_status: [],
          quality_profiles: []
        )

      assert html =~ ~s{id="hero-size-on-disk"}
      assert html =~ "0 B"
    end
  end
end
