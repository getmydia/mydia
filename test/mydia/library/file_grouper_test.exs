defmodule Mydia.Library.FileGrouperTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.FileGrouper

  describe "group_files/1" do
    test "groups empty list" do
      assert FileGrouper.group_files([]) == %{
               series: [],
               movies: [],
               ungrouped: []
             }
    end

    test "groups single movie" do
      matched_files = [
        %{
          file: %{path: "/movies/movie.mkv", size: 1000},
          match_result: %{
            title: "Test Movie",
            provider_id: "123",
            year: 2020,
            parsed_info: %{type: :movie, season: nil, episodes: nil}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.movies) == 1
      assert result.series == []
      assert result.ungrouped == []

      movie = hd(result.movies)
      assert movie.index == 0
      assert movie.match_result.title == "Test Movie"
    end

    test "groups multiple movies" do
      matched_files = [
        %{
          file: %{path: "/movies/movie1.mkv"},
          match_result: %{
            title: "Movie A",
            provider_id: "123",
            year: 2020,
            parsed_info: %{type: :movie}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/movies/movie2.mkv"},
          match_result: %{
            title: "Movie B",
            provider_id: "456",
            year: 2021,
            parsed_info: %{type: :movie}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.movies) == 2
      assert Enum.at(result.movies, 0).index == 0
      assert Enum.at(result.movies, 1).index == 1
    end

    test "groups single TV show episode" do
      matched_files = [
        %{
          file: %{path: "/tv/show.s01e01.mkv"},
          match_result: %{
            title: "Test Show",
            provider_id: "789",
            year: 2019,
            parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.series) == 1
      assert result.movies == []
      assert result.ungrouped == []

      series = hd(result.series)
      assert series.title == "Test Show"
      assert series.provider_id == "789"
      assert series.year == 2019
      assert length(series.seasons) == 1

      season = hd(series.seasons)
      assert season.season_number == 1
      assert length(season.episodes) == 1

      episode = hd(season.episodes)
      assert episode.index == 0
    end

    test "groups multiple episodes of same series into seasons" do
      matched_files = [
        %{
          file: %{path: "/tv/show.s01e01.mkv"},
          match_result: %{
            title: "Show A",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/tv/show.s01e02.mkv"},
          match_result: %{
            title: "Show A",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [2]}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/tv/show.s02e01.mkv"},
          match_result: %{
            title: "Show A",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 2, episodes: [1]}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.series) == 1

      series = hd(result.series)
      assert series.title == "Show A"
      assert length(series.seasons) == 2

      # Seasons should be sorted by season number
      season1 = Enum.at(series.seasons, 0)
      season2 = Enum.at(series.seasons, 1)

      assert season1.season_number == 1
      assert length(season1.episodes) == 2
      assert season2.season_number == 2
      assert length(season2.episodes) == 1
    end

    test "groups multiple different series separately" do
      matched_files = [
        %{
          file: %{path: "/tv/show1.s01e01.mkv"},
          match_result: %{
            title: "Show A",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/tv/show2.s01e01.mkv"},
          match_result: %{
            title: "Show B",
            provider_id: "200",
            year: 2021,
            parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.series) == 2

      # Series should be sorted alphabetically by title
      series1 = Enum.at(result.series, 0)
      series2 = Enum.at(result.series, 1)

      assert series1.title == "Show A"
      assert series2.title == "Show B"
    end

    test "handles episodes without season number (defaults to 0)" do
      matched_files = [
        %{
          file: %{path: "/tv/special.mkv"},
          match_result: %{
            title: "Show Special",
            provider_id: "999",
            year: 2020,
            parsed_info: %{type: :tv_show, season: nil, episodes: [1]}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.series) == 1
      series = hd(result.series)
      assert length(series.seasons) == 1

      season = hd(series.seasons)
      assert season.season_number == 0
    end

    test "groups unmatched files into ungrouped" do
      matched_files = [
        %{
          file: %{path: "/unknown/file.mkv"},
          match_result: nil,
          import_status: :pending
        },
        %{
          file: %{path: "/another/unknown.mp4"},
          match_result: nil,
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert result.series == []
      assert result.movies == []
      assert length(result.ungrouped) == 2

      assert Enum.at(result.ungrouped, 0).index == 0
      assert Enum.at(result.ungrouped, 1).index == 1
    end

    test "handles mixed content types" do
      matched_files = [
        %{
          file: %{path: "/tv/show.s01e01.mkv"},
          match_result: %{
            title: "TV Show",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/movies/movie.mkv"},
          match_result: %{
            title: "Movie",
            provider_id: "200",
            year: 2021,
            parsed_info: %{type: :movie}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/unknown/file.mkv"},
          match_result: nil,
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert length(result.series) == 1
      assert length(result.movies) == 1
      assert length(result.ungrouped) == 1

      # Verify indices are preserved correctly
      assert hd(result.series).seasons |> hd() |> Map.get(:episodes) |> hd() |> Map.get(:index) ==
               0

      assert hd(result.movies).index == 1
      assert hd(result.ungrouped).index == 2
    end

    test "preserves all file metadata during grouping" do
      matched_files = [
        %{
          file: %{path: "/movies/movie.mkv", size: 5000, codec: "h264"},
          match_result: %{
            title: "Movie",
            provider_id: "123",
            year: 2020,
            parsed_info: %{type: :movie}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      movie = hd(result.movies)
      assert movie.file.path == "/movies/movie.mkv"
      assert movie.file.size == 5000
      assert movie.file.codec == "h264"
      assert movie.import_status == :pending
    end

    test "handles unknown media types as ungrouped" do
      matched_files = [
        %{
          file: %{path: "/unknown/type.mkv"},
          match_result: %{
            title: "Unknown Type",
            provider_id: "999",
            year: 2020,
            parsed_info: %{type: :unknown_type}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      assert result.series == []
      assert result.movies == []
      assert length(result.ungrouped) == 1
    end

    test "maintains episode order within seasons" do
      # Create episodes out of order
      matched_files = [
        %{
          file: %{path: "/tv/show.s01e03.mkv"},
          match_result: %{
            title: "Show",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [3]}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/tv/show.s01e01.mkv"},
          match_result: %{
            title: "Show",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [1]}
          },
          import_status: :pending
        },
        %{
          file: %{path: "/tv/show.s01e02.mkv"},
          match_result: %{
            title: "Show",
            provider_id: "100",
            year: 2020,
            parsed_info: %{type: :tv_show, season: 1, episodes: [2]}
          },
          import_status: :pending
        }
      ]

      result = FileGrouper.group_files(matched_files)

      series = hd(result.series)
      season = hd(series.seasons)
      episodes = season.episodes

      # Episodes maintain their insertion order (which reflects file processing order)
      # The indices should be: [0, 1, 2] corresponding to the order they were added
      assert Enum.at(episodes, 0).index == 0
      assert Enum.at(episodes, 1).index == 1
      assert Enum.at(episodes, 2).index == 2
    end
  end

  describe "series_key/1" do
    test "generates key from match result" do
      match = %{title: "Breaking Bad", provider_id: "1396", year: 2008}
      assert FileGrouper.series_key(match) == "Breaking Bad-1396"
    end

    test "generates key from series map" do
      series = %{title: "Game of Thrones", provider_id: "1399", year: 2011}
      assert FileGrouper.series_key(series) == "Game of Thrones-1399"
    end

    test "handles titles with special characters" do
      match = %{title: "It's Always Sunny", provider_id: "2710", year: 2005}
      assert FileGrouper.series_key(match) == "It's Always Sunny-2710"
    end

    test "distinguishes series with same title but different provider IDs" do
      match1 = %{title: "The Office", provider_id: "2316", year: 2005}
      match2 = %{title: "The Office", provider_id: "290", year: 2001}

      key1 = FileGrouper.series_key(match1)
      key2 = FileGrouper.series_key(match2)

      assert key1 != key2
      assert key1 == "The Office-2316"
      assert key2 == "The Office-290"
    end
  end
end
