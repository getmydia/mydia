defmodule Mydia.Downloads.TorrentMatcherCalibrationTest do
  @moduledoc """
  Guards the matcher against confidently matching unrelated titles.

  Every "must not match" pair below scored at or above the 0.8 threshold under
  the pre-gate matcher, so each one characterizes the defect from issue #653
  rather than merely looking plausible. Titles are invented, per the project
  convention against real media titles in tests.
  """
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.TorrentMatcher

  import Mydia.Factory

  # {library title, release title} pairs sharing a year. Each scored >= 0.8
  # before the coverage gate existed.
  @unrelated_movies [
    {"Starveil", "The Star Voyager Chronicle"},
    {"Nightglass", "Nightglider"},
    {"Harrowgate", "Harrow"},
    {"Emberline", "Ember"},
    {"Coldwater", "Cold Harvest"},
    {"Marrow", "Marrowbone Hollow"},
    {"Tidewrack", "Tide"},
    {"Lumen", "Lumberjack Nine"},
    {"Grackle", "Grace Under Fire"}
  ]

  # The TV path has no year term at all, so its bar is a bare 0.8 Jaro-Winkler.
  @unrelated_shows [
    {"Havenridge", "Haven Harbor Line"},
    {"The Quiet Wards", "Quiet Water"},
    {"Northgate Hall", "North Gate Nine Lives"}
  ]

  describe "unrelated movie titles" do
    for {library_title, release_title} <- @unrelated_movies do
      test "#{library_title} does not match #{release_title}" do
        insert(:media_item, %{
          type: "movie",
          title: unquote(library_title),
          year: 2031,
          monitored: true
        })

        torrent_info = %{
          type: :movie,
          title: unquote(release_title),
          year: 2031,
          quality: "1080p"
        }

        assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)
      end
    end
  end

  describe "unrelated show titles" do
    for {library_title, release_title} <- @unrelated_shows do
      test "#{library_title} does not match #{release_title}" do
        show =
          insert(:media_item, %{
            type: "tv_show",
            title: unquote(library_title),
            monitored: true
          })

        insert(:episode, %{media_item: show, season_number: 1, episode_number: 1})

        torrent_info = %{
          type: :tv,
          title: unquote(release_title),
          season: 1,
          episode: 1,
          quality: "1080p"
        }

        assert {:error, reason} = TorrentMatcher.find_match(torrent_info)
        assert reason in [:no_match_found, :episode_not_found]
      end
    end
  end

  describe "legitimate rewordings still match" do
    test "a release carrying a subtitle the library title lacks" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "Vale of Ash",
          year: 2030,
          monitored: true
        })

      torrent_info = %{
        type: :movie,
        title: "Vale of Ash and Ember",
        year: 2030,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
    end

    test "a release differing only by a leading article" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "The Hollow Crown",
          year: 2029,
          monitored: true
        })

      torrent_info = %{
        type: :movie,
        title: "Hollow Crown",
        year: 2029,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
    end

    test "a release matching an alternative title rather than the primary" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "The Quiet Wards",
          original_title: "Los pabellones tranquilos",
          year: 2028,
          monitored: true
        })

      torrent_info = %{
        type: :movie,
        title: "Los pabellones tranquilos",
        year: 2028,
        quality: "1080p"
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
    end
  end

  describe "suggestions stay ungated" do
    test "a near-miss the matcher rejects is still offered as a suggestion" do
      insert(:media_item, %{
        type: "movie",
        title: "Nightglass",
        year: 2029,
        monitored: true
      })

      torrent_info = %{
        type: :movie,
        title: "Nightglider",
        year: 2029,
        quality: "1080p"
      }

      assert {:error, :no_match_found} = TorrentMatcher.find_match(torrent_info)

      suggestions = TorrentMatcher.find_top_candidates(torrent_info)
      assert Enum.any?(suggestions, &(&1.title == "Nightglass"))
    end
  end
end
