defmodule MydiaWeb.MediaLive.Show.HelpersStorageSizeTest do
  use ExUnit.Case, async: true

  import MydiaWeb.MediaLive.Show.Helpers,
    only: [total_media_size: 1, season_total_size: 1]

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}

  describe "total_media_size/1" do
    test "returns 0 for media item with no files" do
      movie = %MediaItem{type: "movie", media_files: []}
      assert total_media_size(movie) == 0

      show = %MediaItem{type: "tv_show", media_files: [], episodes: []}
      assert total_media_size(show) == 0

      assert total_media_size(%{}) == 0
    end

    test "sums size of all media files for a movie" do
      movie = %MediaItem{
        type: "movie",
        media_files: [
          %MediaFile{id: 1, size: 1_000_000},
          %MediaFile{id: 2, size: 2_500_000}
        ]
      }

      assert total_media_size(movie) == 3_500_000
    end

    test "sums size of episode media files for a TV show" do
      show = %MediaItem{
        type: "tv_show",
        media_files: [],
        episodes: [
          %Episode{
            id: 1,
            season_number: 1,
            media_files: [
              %MediaFile{id: 10, size: 500_000_000}
            ]
          },
          %Episode{
            id: 2,
            season_number: 1,
            media_files: [
              %MediaFile{id: 11, size: 600_000_000}
            ]
          },
          %Episode{
            id: 3,
            season_number: 2,
            media_files: [
              %MediaFile{id: 12, size: 700_000_000}
            ]
          }
        ]
      }

      assert total_media_size(show) == 1_800_000_000
    end

    test "includes both direct media files and episode files if present" do
      show = %MediaItem{
        type: "tv_show",
        media_files: [%MediaFile{id: 1, size: 100_000}],
        episodes: [
          %Episode{
            id: 2,
            season_number: 1,
            media_files: [%MediaFile{id: 20, size: 500_000}]
          }
        ]
      }

      assert total_media_size(show) == 600_000
    end

    test "handles nil file sizes safely" do
      movie = %MediaItem{
        type: "movie",
        media_files: [
          %MediaFile{id: 1, size: nil},
          %MediaFile{id: 2, size: 1_000}
        ]
      }

      assert total_media_size(movie) == 1_000
    end
  end

  describe "season_total_size/1" do
    test "returns 0 for empty list of episodes" do
      assert season_total_size([]) == 0
    end

    test "returns 0 when episodes have no media files" do
      episodes = [
        %Episode{id: 1, season_number: 1, media_files: []},
        %Episode{id: 2, season_number: 1, media_files: []}
      ]

      assert season_total_size(episodes) == 0
    end

    test "sums sizes of media files across all episodes in season" do
      episodes = [
        %Episode{
          id: 1,
          season_number: 1,
          media_files: [
            %MediaFile{id: 10, size: 300_000_000},
            %MediaFile{id: 11, size: 200_000_000}
          ]
        },
        %Episode{
          id: 2,
          season_number: 1,
          media_files: [
            %MediaFile{id: 12, size: 500_000_000}
          ]
        }
      ]

      assert season_total_size(episodes) == 1_000_000_000
    end

    test "handles nil media_files or nil sizes safely" do
      episodes = [
        %{id: 1, media_files: nil},
        %{id: 2, media_files: [%{size: nil}, %{size: 400}]}
      ]

      assert season_total_size(episodes) == 400
    end
  end
end
