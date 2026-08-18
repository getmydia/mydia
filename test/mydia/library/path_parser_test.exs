defmodule Mydia.Library.PathParserTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.PathParser

  describe "extract_from_path/1" do
    test "extracts show name and season from standard TV structure" do
      result = PathParser.extract_from_path("/media/tv/The Office/Season 02/episode.mkv")

      assert result == %{show_name: "The Office", season: 2}
    end

    test "extracts show name with hyphen" do
      result = PathParser.extract_from_path("/media/tv/One-Punch Man/Season 03/episode.mkv")

      assert result == %{show_name: "One-Punch Man", season: 3}
    end

    test "handles Season with single digit" do
      result = PathParser.extract_from_path("/media/tv/Bluey/Season 1/episode.mkv")

      assert result == %{show_name: "Bluey", season: 1}
    end

    test "handles Season with leading zero" do
      result = PathParser.extract_from_path("/media/tv/Severance/Season 01/episode.mkv")

      assert result == %{show_name: "Severance", season: 1}
    end

    test "handles S01 folder format" do
      result = PathParser.extract_from_path("/media/tv/Robin Hood/S01/episode.mkv")

      assert result == %{show_name: "Robin Hood", season: 1}
    end

    test "handles Season.XX format with dot" do
      result = PathParser.extract_from_path("/media/tv/Show Name/Season.02/episode.mkv")

      assert result == %{show_name: "Show Name", season: 2}
    end

    test "handles Season-XX format with dash" do
      result = PathParser.extract_from_path("/media/tv/Show Name/Season-03/episode.mkv")

      assert result == %{show_name: "Show Name", season: 3}
    end

    test "handles Specials folder as season 0" do
      result = PathParser.extract_from_path("/media/tv/Doctor Who/Specials/special.mkv")

      assert result == %{show_name: "Doctor Who", season: 0}
    end

    test "handles deep path structure" do
      result =
        PathParser.extract_from_path(
          "/home/user/media/library/television/The Mandalorian/Season 02/episode.mkv"
        )

      assert result == %{show_name: "The Mandalorian", season: 2}
    end

    test "returns nil for flat file structure" do
      result = PathParser.extract_from_path("/downloads/random_file.mkv")

      assert result == nil
    end

    test "returns nil for movie-like structure" do
      result = PathParser.extract_from_path("/media/movies/Inception (2010)/movie.mkv")

      assert result == nil
    end

    test "returns nil for file without enough path segments" do
      result = PathParser.extract_from_path("/file.mkv")

      assert result == nil
    end

    test "returns nil for non-binary input" do
      assert PathParser.extract_from_path(nil) == nil
      assert PathParser.extract_from_path(123) == nil
    end

    test "ignores common root folders as show names" do
      result = PathParser.extract_from_path("/media/Season 01/episode.mkv")

      assert result == nil
    end

    test "ignores tv as show name" do
      result = PathParser.extract_from_path("/tv/Season 01/episode.mkv")

      assert result == nil
    end
  end

  describe "parse_season_folder/1" do
    test "parses Season 01" do
      assert PathParser.parse_season_folder("Season 01") == {:ok, 1}
    end

    test "parses Season 1" do
      assert PathParser.parse_season_folder("Season 1") == {:ok, 1}
    end

    test "parses Season.05" do
      assert PathParser.parse_season_folder("Season.05") == {:ok, 5}
    end

    test "parses Season-10" do
      assert PathParser.parse_season_folder("Season-10") == {:ok, 10}
    end

    test "parses S01" do
      assert PathParser.parse_season_folder("S01") == {:ok, 1}
    end

    test "parses S1" do
      assert PathParser.parse_season_folder("S1") == {:ok, 1}
    end

    test "parses Specials as season 0" do
      assert PathParser.parse_season_folder("Specials") == {:ok, 0}
    end

    test "parses Special (singular) as season 0" do
      assert PathParser.parse_season_folder("Special") == {:ok, 0}
    end

    test "returns error for non-season folder" do
      assert PathParser.parse_season_folder("The Office") == :error
    end

    test "returns error for random text" do
      assert PathParser.parse_season_folder("random") == :error
    end

    test "returns error for non-binary input" do
      assert PathParser.parse_season_folder(nil) == :error
    end

    test "handles case insensitive matching" do
      assert PathParser.parse_season_folder("season 01") == {:ok, 1}
      assert PathParser.parse_season_folder("SEASON 01") == {:ok, 1}
      assert PathParser.parse_season_folder("s01") == {:ok, 1}
    end
  end

  describe "is_tv_path?/1" do
    test "returns true for TV show path" do
      assert PathParser.is_tv_path?("/media/tv/Show Name/Season 01/episode.mkv") == true
    end

    test "returns false for movie path" do
      assert PathParser.is_tv_path?("/media/movies/Movie (2020)/movie.mkv") == false
    end

    test "returns false for downloads path" do
      assert PathParser.is_tv_path?("/downloads/random.mkv") == false
    end

    test "returns false for non-binary input" do
      assert PathParser.is_tv_path?(nil) == false
    end
  end

  describe "real-world examples from task-265" do
    test "extracts Bluey from folder even with wrong filename" do
      # This file has "Playdate 2025" in the filename but is in Bluey folder
      result =
        PathParser.extract_from_path(
          "/media/tv/Bluey/Season 03/Playdate 2025 2160p AMZN WEB-DL.mkv"
        )

      assert result == %{show_name: "Bluey", season: 3}
    end

    test "extracts Bluey from folder with completely wrong show in filename" do
      # This file has "Naruto Gaiden" in the filename but is in Bluey folder
      result =
        PathParser.extract_from_path("/media/tv/Bluey/Season 02/Naruto Gaiden 1A S02E01 720p.mkv")

      assert result == %{show_name: "Bluey", season: 2}
    end

    test "extracts Robin Hood from folder" do
      result =
        PathParser.extract_from_path(
          "/media/tv/Robin Hood/Season 01/Robin.Hood.2025.S01E01.720p.mkv"
        )

      assert result == %{show_name: "Robin Hood", season: 1}
    end

    test "extracts Severance from folder" do
      result =
        PathParser.extract_from_path("/media/tv/Severance/Season 01/Severance.S01E08.mkv")

      assert result == %{show_name: "Severance", season: 1}
    end

    test "extracts One-Punch Man from folder" do
      result =
        PathParser.extract_from_path("/media/tv/One-Punch Man/Season 03/One-Punch.Man.S03E04.mkv")

      assert result == %{show_name: "One-Punch Man", season: 3}
    end
  end

  describe "parse_movie_folder/1" do
    test "parses movie folder with year and TMDB ID" do
      result = PathParser.parse_movie_folder("Twister (1996) [tmdb-664]")

      assert result == %{
               title: "Twister",
               year: 1996,
               external_id: "664",
               external_provider: :tmdb
             }
    end

    test "parses movie folder with year only" do
      result = PathParser.parse_movie_folder("The Matrix (1999)")

      assert result == %{
               title: "The Matrix",
               year: 1999,
               external_id: nil,
               external_provider: nil
             }
    end

    test "parses movie folder with TMDB ID only (no year)" do
      result = PathParser.parse_movie_folder("Inception [tmdb-27205]")

      assert result == %{
               title: "Inception",
               year: nil,
               external_id: "27205",
               external_provider: :tmdb
             }
    end

    test "parses movie folder with TVDB ID" do
      result = PathParser.parse_movie_folder("Some Movie (2020) [tvdb-12345]")

      assert result == %{
               title: "Some Movie",
               year: 2020,
               external_id: "12345",
               external_provider: :tvdb
             }
    end

    test "parses movie folder with IMDB ID" do
      result = PathParser.parse_movie_folder("Dark Knight (2008) [imdb-tt0468569]")

      assert result == %{
               title: "Dark Knight",
               year: 2008,
               external_id: "tt0468569",
               external_provider: :imdb
             }
    end

    test "handles case-insensitive provider names" do
      result = PathParser.parse_movie_folder("Movie (2020) [TMDB-123]")

      assert result == %{
               title: "Movie",
               year: 2020,
               external_id: "123",
               external_provider: :tmdb
             }
    end

    test "returns nil for folder without year or external ID" do
      result = PathParser.parse_movie_folder("Just A Folder Name")

      assert result == nil
    end

    test "returns nil for empty string" do
      assert PathParser.parse_movie_folder("") == nil
    end

    test "returns nil for nil input" do
      assert PathParser.parse_movie_folder(nil) == nil
    end

    test "handles title with special characters" do
      result = PathParser.parse_movie_folder("Mission: Impossible (1996) [tmdb-954]")

      assert result == %{
               title: "Mission: Impossible",
               year: 1996,
               external_id: "954",
               external_provider: :tmdb
             }
    end

    test "handles title with numbers" do
      result = PathParser.parse_movie_folder("2001 A Space Odyssey (1968) [tmdb-62]")

      assert result == %{
               title: "2001 A Space Odyssey",
               year: 1968,
               external_id: "62",
               external_provider: :tmdb
             }
    end

    test "handles real-world folder name with quality info in filename" do
      # The folder name should be parsed, not the filename
      result = PathParser.parse_movie_folder("Twister (1996) [tmdb-664]")

      assert result == %{
               title: "Twister",
               year: 1996,
               external_id: "664",
               external_provider: :tmdb
             }
    end
  end

  describe "extract_movie_from_path/1" do
    test "extracts movie metadata from full path" do
      result =
        PathParser.extract_movie_from_path(
          "/media/library/movies/MOVIES/Twister (1996) [tmdb-664]/Twister.1996.German.TrueHD.Atmos.1080p.BluRay.x264.mkv"
        )

      assert result == %{
               title: "Twister",
               year: 1996,
               external_id: "664",
               external_provider: :tmdb
             }
    end

    test "extracts movie from path without TMDB ID" do
      result =
        PathParser.extract_movie_from_path(
          "/media/movies/The Shawshank Redemption (1994)/movie.mkv"
        )

      assert result == %{
               title: "The Shawshank Redemption",
               year: 1994,
               external_id: nil,
               external_provider: nil
             }
    end

    test "returns nil for file not in movie folder structure" do
      result = PathParser.extract_movie_from_path("/downloads/random_movie.mkv")

      assert result == nil
    end

    test "returns nil for TV show structure" do
      result =
        PathParser.extract_movie_from_path("/media/tv/The Office/Season 01/episode.mkv")

      assert result == nil
    end

    test "returns nil for non-binary input" do
      assert PathParser.extract_movie_from_path(nil) == nil
    end
  end

  describe "parse_tv_show_folder/1" do
    test "parses TV show folder with TVDB ID" do
      result = PathParser.parse_tv_show_folder("Breaking Bad [tvdb-81189]")

      assert result == %{
               title: "Breaking Bad",
               year: nil,
               external_id: "81189",
               external_provider: :tvdb
             }
    end

    test "parses TV show folder with year and TMDB ID" do
      result = PathParser.parse_tv_show_folder("The Office (2005) [tmdb-2316]")

      assert result == %{
               title: "The Office",
               year: 2005,
               external_id: "2316",
               external_provider: :tmdb
             }
    end

    test "parses TV show folder with year only" do
      result = PathParser.parse_tv_show_folder("Bluey (2018)")

      assert result == %{
               title: "Bluey",
               year: 2018,
               external_id: nil,
               external_provider: nil
             }
    end

    test "parses TV show folder with title only (no year or ID)" do
      result = PathParser.parse_tv_show_folder("One-Punch Man")

      assert result == %{
               title: "One-Punch Man",
               year: nil,
               external_id: nil,
               external_provider: nil
             }
    end

    test "parses TV show folder with IMDB ID" do
      result = PathParser.parse_tv_show_folder("Game of Thrones (2011) [imdb-tt0944947]")

      assert result == %{
               title: "Game of Thrones",
               year: 2011,
               external_id: "tt0944947",
               external_provider: :imdb
             }
    end

    test "handles case-insensitive provider names" do
      result = PathParser.parse_tv_show_folder("Show Name [TVDB-12345]")

      assert result == %{
               title: "Show Name",
               year: nil,
               external_id: "12345",
               external_provider: :tvdb
             }
    end

    test "parses folder with special characters in title" do
      result =
        PathParser.parse_tv_show_folder("Marvel's Agents of S.H.I.E.L.D. (2013) [tmdb-1403]")

      assert result == %{
               title: "Marvel's Agents of S.H.I.E.L.D.",
               year: 2013,
               external_id: "1403",
               external_provider: :tmdb
             }
    end

    test "returns nil for nil input" do
      assert PathParser.parse_tv_show_folder(nil) == nil
    end
  end

  describe "extract_tv_show_from_path/1" do
    test "extracts TV show metadata with TVDB ID from full path" do
      result =
        PathParser.extract_tv_show_from_path(
          "/media/tv/Breaking Bad [tvdb-81189]/Season 01/episode.mkv"
        )

      assert result == %{
               title: "Breaking Bad",
               year: nil,
               external_id: "81189",
               external_provider: :tvdb
             }
    end

    test "extracts TV show metadata with year and TMDB ID from full path" do
      result =
        PathParser.extract_tv_show_from_path(
          "/media/tv/The Office (2005) [tmdb-2316]/Season 02/episode.mkv"
        )

      assert result == %{
               title: "The Office",
               year: 2005,
               external_id: "2316",
               external_provider: :tmdb
             }
    end

    test "extracts TV show metadata with just title from full path" do
      result =
        PathParser.extract_tv_show_from_path("/media/tv/Bluey/Season 03/episode.mkv")

      assert result == %{
               title: "Bluey",
               year: nil,
               external_id: nil,
               external_provider: nil
             }
    end

    test "extracts TV show metadata with year from full path" do
      result =
        PathParser.extract_tv_show_from_path("/media/tv/Bluey (2018)/Season 03/episode.mkv")

      assert result == %{
               title: "Bluey",
               year: 2018,
               external_id: nil,
               external_provider: nil
             }
    end

    test "handles deep path structure with TV show metadata" do
      result =
        PathParser.extract_tv_show_from_path(
          "/home/user/media/library/tv/Severance (2022) [tmdb-95396]/Season 01/episode.mkv"
        )

      assert result == %{
               title: "Severance",
               year: 2022,
               external_id: "95396",
               external_provider: :tmdb
             }
    end

    test "handles Specials folder" do
      result =
        PathParser.extract_tv_show_from_path(
          "/media/tv/Doctor Who (2005) [tvdb-78804]/Specials/special.mkv"
        )

      assert result == %{
               title: "Doctor Who",
               year: 2005,
               external_id: "78804",
               external_provider: :tvdb
             }
    end

    test "handles S01 folder format" do
      result =
        PathParser.extract_tv_show_from_path("/media/tv/Show Name [tmdb-123]/S01/episode.mkv")

      assert result == %{
               title: "Show Name",
               year: nil,
               external_id: "123",
               external_provider: :tmdb
             }
    end

    test "returns nil for file not in TV folder structure" do
      result = PathParser.extract_tv_show_from_path("/downloads/random_file.mkv")

      assert result == nil
    end

    test "returns nil for movie folder structure" do
      result =
        PathParser.extract_tv_show_from_path("/media/movies/Twister (1996) [tmdb-664]/movie.mkv")

      assert result == nil
    end

    test "returns nil for too short path" do
      result = PathParser.extract_tv_show_from_path("/file.mkv")

      assert result == nil
    end

    test "returns nil for non-binary input" do
      assert PathParser.extract_tv_show_from_path(nil) == nil
    end
  end

  describe "season_from_segment/1" do
    test "reads the season number from every supported folder form" do
      assert PathParser.season_from_segment("Season 01") == {:ok, 1}
      assert PathParser.season_from_segment("Season 1") == {:ok, 1}
      assert PathParser.season_from_segment("Season.02") == {:ok, 2}
      assert PathParser.season_from_segment("S03") == {:ok, 3}
      assert PathParser.season_from_segment("s3") == {:ok, 3}
    end

    test "treats specials as season zero" do
      assert PathParser.season_from_segment("Specials") == {:ok, 0}
      assert PathParser.season_from_segment("Special") == {:ok, 0}
    end

    test "rejects anything that is not a season folder" do
      assert PathParser.season_from_segment("Breaking Bad") == :error
      assert PathParser.season_from_segment("1080p") == :error
      assert PathParser.season_from_segment("") == :error
    end
  end
end
