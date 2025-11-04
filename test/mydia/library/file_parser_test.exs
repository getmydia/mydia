defmodule Mydia.Library.FileParserTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.FileParser

  describe "parse_movie/1" do
    test "parses basic movie with year and quality" do
      result = FileParser.parse("Movie Title (2020) 1080p.mkv")

      assert result.type == :movie
      assert result.title == "Movie Title"
      assert result.year == 2020
      assert result.quality.resolution == "1080p"
      assert result.confidence > 0.8
    end

    test "parses scene release format" do
      result = FileParser.parse("Movie.Title.2020.2160p.BluRay.x265-GROUP.mkv")

      assert result.type == :movie
      assert result.title == "Movie Title"
      assert result.year == 2020
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x265"
      assert result.release_group == "GROUP"
    end

    test "parses movie with HDR format" do
      result = FileParser.parse("Awesome.Movie.2021.2160p.WEB-DL.HDR10.x265.mkv")

      assert result.type == :movie
      assert result.title == "Awesome Movie"
      assert result.year == 2021
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.hdr_format == "HDR10"
      assert result.quality.codec == "x265"
    end

    test "parses movie with audio codec" do
      result = FileParser.parse("Great Film (2019) 1080p BluRay DTS-HD.mkv")

      assert result.type == :movie
      assert result.title == "Great Film"
      assert result.year == 2019
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.audio == "DTS-HD"
    end

    test "handles movie with year in title" do
      result = FileParser.parse("2001 A Space Odyssey (1968) 1080p.mkv")

      assert result.type == :movie
      assert result.title == "2001 A Space Odyssey"
      assert result.year == 1968
    end

    test "parses movie without year" do
      result = FileParser.parse("Some Movie 1080p.mkv")

      assert result.type == :movie
      assert result.title == "Some Movie"
      assert result.year == nil
      assert result.quality.resolution == "1080p"
      assert result.confidence > 0.6
    end

    test "handles various separators" do
      result1 = FileParser.parse("Movie_Name_2020_1080p.mkv")
      result2 = FileParser.parse("Movie.Name.2020.1080p.mkv")
      result3 = FileParser.parse("Movie Name 2020 1080p.mkv")

      assert result1.title == "Movie Name"
      assert result2.title == "Movie Name"
      assert result3.title == "Movie Name"

      assert result1.year == 2020
      assert result2.year == 2020
      assert result3.year == 2020
    end

    test "parses 4K and UHD resolutions" do
      result1 = FileParser.parse("Movie 2020 4K.mkv")
      result2 = FileParser.parse("Movie 2020 UHD.mkv")

      assert result1.quality.resolution == "4K"
      assert result2.quality.resolution == "UHD"
    end

    test "handles P2P release naming" do
      result = FileParser.parse("The.Movie.2020.1080p.WEBRip.x264-RARBG.mkv")

      assert result.title == "The Movie"
      assert result.quality.source == "WEBRip"
      assert result.release_group == "RARBG"
    end

    test "parses movie with Dolby Vision" do
      result = FileParser.parse("Epic.Film.2021.2160p.WEB.DolbyVision.mkv")

      assert result.quality.hdr_format == "DolbyVision"
    end
  end

  describe "parse_tv_show/1" do
    test "parses standard S01E01 format" do
      result = FileParser.parse("Show Name S01E05 720p.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [5]
      assert result.quality.resolution == "720p"
      assert result.confidence > 0.8
    end

    test "parses lowercase s01e01 format" do
      result = FileParser.parse("show.name.s02e10.1080p.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 2
      assert result.episodes == [10]
    end

    test "parses 1x01 format" do
      result = FileParser.parse("Show Name 3x12 720p.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 3
      assert result.episodes == [12]
    end

    test "parses multi-episode format S01E01-E03" do
      result = FileParser.parse("Show.Name.S01E01-E03.1080p.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [1, 2, 3]
    end

    test "parses TV show with quality and codec" do
      result = FileParser.parse("Great.Show.S02E08.1080p.WEB.H264-GROUP.mkv")

      assert result.type == :tv_show
      assert result.title == "Great Show"
      assert result.season == 2
      assert result.episodes == [8]
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB"
      assert result.quality.codec == "H264"
      assert result.release_group == "GROUP"
    end

    test "parses TV show with year" do
      result = FileParser.parse("Show Name 2019 S01E01.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.year == 2019
      assert result.season == 1
      assert result.episodes == [1]
    end

    test "handles season 0 (specials)" do
      result = FileParser.parse("Show Name S00E01.mkv")

      assert result.type == :tv_show
      assert result.season == 0
      assert result.episodes == [1]
    end

    test "parses verbose format 'Season 1 Episode 1'" do
      result = FileParser.parse("Show Name Season 1 Episode 5.mkv")

      assert result.type == :tv_show
      assert result.season == 1
      assert result.episodes == [5]
    end

    test "parses WEB-DL TV show" do
      result = FileParser.parse("Show.S01E01.1080p.WEB-DL.DD5.1.H264.mkv")

      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "DD5.1"
      assert result.quality.codec == "H264"
    end

    test "handles two-digit episodes" do
      result = FileParser.parse("Show.Name.S05E23.mkv")

      assert result.season == 5
      assert result.episodes == [23]
    end
  end

  describe "parse/1 - auto-detection" do
    test "automatically detects TV show" do
      result = FileParser.parse("Show Name S01E01.mkv")

      assert result.type == :tv_show
    end

    test "automatically detects movie" do
      result = FileParser.parse("Movie Name (2020).mkv")

      assert result.type == :movie
    end

    test "includes original filename in result" do
      result = FileParser.parse("Movie.Name.2020.mkv")

      assert result.original_filename == "Movie.Name.2020.mkv"
    end

    test "returns unknown for ambiguous files" do
      result = FileParser.parse("randomfile.mkv")

      assert result.type == :unknown
      assert result.confidence < 0.5
    end
  end

  describe "edge cases" do
    test "handles file with full path" do
      result = FileParser.parse("/media/movies/Movie Title (2020) 1080p.mkv")

      assert result.title == "Movie Title"
      assert result.year == 2020
    end

    test "handles complex movie title with special chars" do
      result = FileParser.parse("Movie: The Beginning (2020) 1080p.mkv")

      assert result.title =~ "Movie"
      assert result.year == 2020
    end

    test "handles TV show with dots as separators" do
      result = FileParser.parse("My.Great.Show.S01E01.720p.mkv")

      assert result.title == "My Great Show"
      assert result.season == 1
    end

    test "handles mixed case" do
      result = FileParser.parse("ThE.MoViE.2020.1080P.mkv")

      assert result.title == "The Movie"
      assert result.quality.resolution == "1080p"
    end

    test "handles BDRip source" do
      result = FileParser.parse("Movie 2020 1080p BDRip.mkv")

      assert result.quality.source == "BDRip"
    end

    test "handles HDTV source" do
      result = FileParser.parse("Show S01E01 720p HDTV.mkv")

      assert result.quality.source == "HDTV"
    end

    test "handles XviD codec" do
      result = FileParser.parse("Old Movie 2005 DVDRip XviD.avi")

      assert result.quality.source == "DVDRip"
      assert result.quality.codec == "XviD"
    end

    test "handles AV1 codec" do
      result = FileParser.parse("Modern Movie 2023 1080p AV1.mkv")

      assert result.quality.codec == "AV1"
    end

    test "handles HDR10+ format" do
      result = FileParser.parse("Movie 2021 2160p HDR10+.mkv")

      assert result.quality.hdr_format == "HDR10+"
    end

    test "handles Atmos audio" do
      result = FileParser.parse("Movie 2020 1080p Atmos.mkv")

      assert result.quality.audio == "Atmos"
    end

    test "handles TrueHD audio" do
      result = FileParser.parse("Movie 2020 1080p TrueHD.mkv")

      assert result.quality.audio == "TrueHD"
    end

    test "parses movie with multiple quality markers" do
      result =
        FileParser.parse(
          "Epic.Movie.2021.2160p.UHD.BluRay.HDR10.DolbyVision.TrueHD.Atmos.7.1.x265.mkv"
        )

      assert result.title == "Epic Movie"
      assert result.year == 2021
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "BluRay"
      # Should pick up at least some of these
      assert result.quality.codec == "x265"
    end

    test "handles empty or very short filenames gracefully" do
      result = FileParser.parse("a.mkv")

      assert result.type == :unknown
      assert result.confidence < 0.5
    end

    test "handles movie with brackets instead of parentheses for year" do
      result = FileParser.parse("Movie Title [2020] 1080p.mkv")

      assert result.title == "Movie Title"
      assert result.year == 2020
    end

    test "handles year in filename without parentheses" do
      result = FileParser.parse("Movie Title 2020 1080p.mkv")

      assert result.title == "Movie Title"
      assert result.year == 2020
    end
  end

  describe "confidence scoring" do
    test "high confidence for well-formed movie name" do
      result = FileParser.parse("Movie Title (2020) 1080p BluRay.mkv")

      assert result.confidence > 0.85
    end

    test "medium confidence for movie without year" do
      result = FileParser.parse("Movie Title 1080p.mkv")

      assert result.confidence > 0.6
      assert result.confidence < 0.85
    end

    test "lower confidence for minimal information" do
      result = FileParser.parse("movie.mkv")

      assert result.confidence < 0.7
    end

    test "high confidence for TV show with season/episode" do
      result = FileParser.parse("Show Name S01E01 1080p.mkv")

      assert result.confidence > 0.85
    end
  end

  describe "real-world examples" do
    test "parses Sonarr/Radarr style naming" do
      result = FileParser.parse("The.Mandalorian.S02E05.1080p.WEB.H264-GLHF.mkv")

      assert result.type == :tv_show
      assert result.title == "The Mandalorian"
      assert result.season == 2
      assert result.episodes == [5]
      assert result.quality.resolution == "1080p"
      assert result.release_group == "GLHF"
    end

    test "parses Plex-style naming" do
      result = FileParser.parse("Inception (2010)/Inception (2010) - 1080p.mkv")

      assert result.type == :movie
      assert result.title == "Inception"
      assert result.year == 2010
    end

    test "parses common torrent naming" do
      result = FileParser.parse("Breaking.Bad.S05E16.1080p.BluRay.x264-ROVERS[rarbg].mkv")

      assert result.type == :tv_show
      assert result.title == "Breaking Bad"
      assert result.season == 5
      assert result.episodes == [16]
    end

    test "parses 4K remux" do
      result = FileParser.parse("Avatar.2009.2160p.UHD.BluRay.REMUX.HDR.HEVC.Atmos-FGT.mkv")

      assert result.type == :movie
      assert result.title == "Avatar"
      assert result.year == 2009
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "HEVC"
      assert result.quality.audio == "Atmos"
    end
  end
end
