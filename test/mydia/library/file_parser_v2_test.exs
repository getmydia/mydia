defmodule Mydia.Library.FileParser.V2Test do
  use ExUnit.Case, async: true

  alias Mydia.Library.FileParser.V2, as: FileParser
  alias Mydia.Library.Structs.Quality

  describe "parse_movie/1 - basic functionality" do
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

  describe "parse_tv_show/1 - basic functionality" do
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

    test "handles DDP5.1 audio codec" do
      result = FileParser.parse("Movie 2020 1080p WEB-DL DDP5.1 Atmos.mkv")

      assert result.quality.audio == "DDP5.1"
      assert result.title == "Movie"
      assert result.year == 2020
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

    test "parses movie with 10 bit pattern (with space)" do
      result = FileParser.parse("The Matrix Reloaded (2003) BDRip 2160p-NVENC 10 bit [HDR].mkv")

      assert result.type == :movie
      assert result.title == "The Matrix Reloaded"
      assert result.year == 2003
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "BDRip"
    end

    test "parses movie with 10bit pattern (no space)" do
      result = FileParser.parse("Inception (2010) 1080p BluRay 10bit x265.mkv")

      assert result.type == :movie
      assert result.title == "Inception"
      assert result.year == 2010
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x265"
    end

    test "parses movie with 8 bit pattern" do
      result = FileParser.parse("Movie Title 2020 1080p WEB-DL 8 bit x264.mkv")

      assert result.type == :movie
      assert result.title == "Movie Title"
      assert result.year == 2020
      assert result.quality.resolution == "1080p"
    end

    test "parses movie with NVENC codec" do
      result = FileParser.parse("Test Movie (2021) 1080p-NVENC.mkv")

      assert result.type == :movie
      assert result.title == "Test Movie"
      assert result.year == 2021
      assert result.quality.resolution == "1080p"
    end

    test "parses movie with VMAF quality metric" do
      result =
        FileParser.parse("Dune.Part.Two.2024.HDR.BluRay.2160p.x265.7.1.aac.VMAF96-Rosy.mkv")

      assert result.type == :movie
      assert result.title == "Dune Part Two"
      assert result.year == 2024
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x265"
      assert result.quality.hdr_format == "HDR"
      # Audio codec case is preserved from the filename (lowercase "aac")
      assert result.quality.audio == "aac"
      assert result.release_group == "Rosy"
    end

    test "parses Black Phone 2 with DDP5.1 audio codec and dot-separated release group" do
      result =
        FileParser.parse("Black Phone 2. 2025 1080P WEB-DL DDP5.1 Atmos. X265. POOLTED.mkv")

      assert result.type == :movie

      # With sequential extraction and updated release group pattern, "POOLTED" is correctly extracted
      assert result.title == "Black Phone 2"
      assert result.year == 2025
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "DDP5.1"
      # Codec case is preserved from the filename (uppercase "X265")
      assert result.quality.codec == "X265"
      # Release group detected with updated pattern supporting dots/spaces
      assert result.release_group == "POOLTED"
    end
  end

  describe "codec variations - Phase 1 regex patterns" do
    test "handles audio codec variations with dots" do
      # DD5.1 with dot
      result1 = FileParser.parse("Movie.2024.1080p.DD5.1.mkv")
      assert result1.quality.audio == "DD5.1"
      assert result1.title == "Movie"

      # DDP5.1 with dot
      result2 = FileParser.parse("Movie.2024.1080p.DDP5.1.mkv")
      assert result2.quality.audio == "DDP5.1"
      assert result2.title == "Movie"
    end

    test "handles audio codec variations without dots" do
      # DD51 without dot
      result1 = FileParser.parse("Movie.2024.1080p.DD51.mkv")
      assert result1.quality.audio == "DD51"
      assert result1.title == "Movie"

      # DDP51 without dot
      result2 = FileParser.parse("Movie.2024.1080p.DDP51.mkv")
      assert result2.quality.audio == "DDP51"
      assert result2.title == "Movie"
    end

    test "handles EAC3 audio codec (alternative name for DDP)" do
      result = FileParser.parse("Movie.2024.1080p.EAC3.mkv")
      assert result.quality.audio == "EAC3"
      assert result.title == "Movie"
    end

    test "handles DD+ audio codec" do
      result = FileParser.parse("Movie.2024.1080p.DD+.mkv")
      # DD+ is parsed as "DD" since + is normalized away
      assert result.quality.audio == "DD"
      # The + character is normalized to space and removed during title cleaning
      assert result.title == "Movie"
    end

    test "handles TrueHD with channel specification" do
      result = FileParser.parse("Movie.2024.1080p.TrueHD.7.1.mkv")
      # TrueHD pattern captures the full string including channel spec
      assert result.quality.audio == "TrueHD 7.1"
      assert result.title == "Movie"
    end

    test "handles DTS variants" do
      # DTS-HD
      result1 = FileParser.parse("Movie.2024.1080p.DTS-HD.mkv")
      assert result1.quality.audio == "DTS-HD"

      # DTS-HD.MA
      result2 = FileParser.parse("Movie.2024.1080p.DTS-HD.MA.mkv")
      assert result2.quality.audio == "DTS-HD.MA"

      # DTS-X
      result3 = FileParser.parse("Movie.2024.1080p.DTS-X.mkv")
      assert result3.quality.audio == "DTS-X"

      # Plain DTS
      result4 = FileParser.parse("Movie.2024.1080p.DTS.mkv")
      assert result4.quality.audio == "DTS"
    end

    test "handles video codec variations with dots" do
      # x.264 - dots are normalized to spaces, then restored to dots
      result1 = FileParser.parse("Movie.2024.1080p.x.264.mkv")
      assert result1.quality.codec == "x.264"
      assert result1.title == "Movie"

      # H.264 - dots are normalized to spaces, then restored to dots
      result2 = FileParser.parse("Movie.2024.1080p.H.264.mkv")
      assert result2.quality.codec == "H.264"
      assert result2.title == "Movie"
    end

    test "handles video codec variations without dots" do
      # x264
      result1 = FileParser.parse("Movie.2024.1080p.x264.mkv")
      assert result1.quality.codec == "x264"

      # h264
      result2 = FileParser.parse("Movie.2024.1080p.h264.mkv")
      assert result2.quality.codec == "h264"
    end

    test "handles x265 and h265 variations" do
      result1 = FileParser.parse("Movie.2024.1080p.x265.mkv")
      assert result1.quality.codec == "x265"

      result2 = FileParser.parse("Movie.2024.1080p.h265.mkv")
      assert result2.quality.codec == "h265"

      # x.265 - dots are normalized to spaces, then restored to dots
      result3 = FileParser.parse("Movie.2024.1080p.x.265.mkv")
      assert result3.quality.codec == "x.265"
    end

    test "handles HEVC and AVC codec names" do
      result1 = FileParser.parse("Movie.2024.1080p.HEVC.mkv")
      assert result1.quality.codec == "HEVC"

      result2 = FileParser.parse("Movie.2024.1080p.AVC.mkv")
      assert result2.quality.codec == "AVC"
    end

    test "handles resolution pattern variations" do
      # Lowercase p
      result1 = FileParser.parse("Movie.2024.1080p.mkv")
      assert result1.quality.resolution == "1080p"

      # Uppercase P - normalized to lowercase
      result2 = FileParser.parse("Movie.2024.1080P.mkv")
      assert result2.quality.resolution == "1080p"

      # 4K, 8K, UHD
      result3 = FileParser.parse("Movie.2024.4K.mkv")
      assert result3.quality.resolution == "4K"

      result4 = FileParser.parse("Movie.2024.UHD.mkv")
      assert result4.quality.resolution == "UHD"
    end

    test "handles source pattern variations" do
      # WEB
      result1 = FileParser.parse("Movie.2024.1080p.WEB.mkv")
      assert result1.quality.source == "WEB"

      # WEB-DL
      result2 = FileParser.parse("Movie.2024.1080p.WEB-DL.mkv")
      assert result2.quality.source == "WEB-DL"

      # WEBRip
      result3 = FileParser.parse("Movie.2024.1080p.WEBRip.mkv")
      assert result3.quality.source == "WEBRip"

      # DVD
      result4 = FileParser.parse("Movie.2024.480p.DVD.mkv")
      assert result4.quality.source == "DVD"

      # DVDRip
      result5 = FileParser.parse("Movie.2024.480p.DVDRip.mkv")
      assert result5.quality.source == "DVDRip"
    end

    test "complex real-world example with multiple variations" do
      result =
        FileParser.parse("The.Matrix.1999.1080p.BluRay.x.264.DTS-HD.MA.5.1-GROUP.mkv")

      assert result.type == :movie
      assert result.title == "The Matrix"
      assert result.year == 1999
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x.264"
      assert result.quality.audio == "DTS-HD.MA"
      assert result.release_group == "GROUP"
    end

    test "handles DDP7.1 audio codec" do
      result = FileParser.parse("Movie.2024.1080p.DDP7.1.mkv")
      assert result.quality.audio == "DDP7.1"
      assert result.title == "Movie"
    end

    test "handles AAC variations" do
      result1 = FileParser.parse("Movie.2024.1080p.AAC.mkv")
      assert result1.quality.audio == "AAC"

      result2 = FileParser.parse("Movie.2024.1080p.AAC-LC.mkv")
      assert result2.quality.audio == "AAC-LC"
    end
  end

  describe "sequential extraction - title isolation" do
    test "correctly isolates title after removing all patterns" do
      result =
        FileParser.parse("The.Dark.Knight.2008.2160p.UHD.BluRay.x265.HDR.DTS-HD.MA.5.1-GROUP.mkv")

      assert result.title == "The Dark Knight"
      assert result.year == 2008
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x265"
      assert result.quality.hdr_format == "HDR"
      assert result.quality.audio == "DTS-HD.MA"
      assert result.release_group == "GROUP"
    end

    test "handles title with no quality markers" do
      result = FileParser.parse("Just A Title 2024.mkv")

      assert result.title == "Just A Title"
      assert result.year == 2024
      assert Quality.empty?(result.quality)
    end

    test "handles complex title with numbers" do
      result = FileParser.parse("Mission Impossible 7 Dead Reckoning Part 1 (2023) 1080p.mkv")

      assert result.title == "Mission Impossible 7 Dead Reckoning Part 1"
      assert result.year == 2023
    end

    test "removes all noise patterns from title" do
      result =
        FileParser.parse("Movie.Name.2024.PROPER.REPACK.1080p.WEB-DL.10bit.DDP5.1.HEVC-GROUP.mkv")

      assert result.title == "Movie Name"
      assert result.year == 2024
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.codec == "HEVC"
      assert result.quality.audio == "DDP5.1"
      assert result.release_group == "GROUP"
    end
  end

  describe "V2 improvements over V1" do
    test "correctly handles Black Phone 2 with DDP5.1" do
      # This was the motivating example for V2
      result =
        FileParser.parse("Black Phone 2. 2025 1080P WEB-DL DDP5.1 Atmos. X265. POOLTED.mkv")

      assert result.type == :movie
      assert result.year == 2025
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "DDP5.1"
      assert result.quality.codec == "X265"
      # Title is cleanly extracted with sequential extraction and release group pattern update
      assert result.title == "Black Phone 2"
      assert result.release_group == "POOLTED"
    end

    test "handles codec variations without list maintenance" do
      # New codec variant not in original lists
      result = FileParser.parse("Movie.2024.1080p.DDP9.1.mkv")

      # Should still extract DDP9.1 as audio codec
      assert result.quality.audio == "DDP9.1"
      assert result.title == "Movie"
    end

    test "handles complex nested patterns" do
      result =
        FileParser.parse("Show.Name.S01E05.1080p.AMZN.WEB-DL.DDP5.1.H.264.HYBRID.REMUX-GROUP.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [5]
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "DDP5.1"
      assert result.quality.codec == "H.264"
      assert result.release_group == "GROUP"
    end
  end

  describe "Phase 3: Standardization Layer" do
    test "standardizes audio codec - Dolby Digital Plus variations" do
      # DDP5.1 → Dolby Digital Plus 5.1
      result1 = FileParser.parse("Movie.2024.1080p.DDP5.1.mkv", standardize: true)
      assert result1.quality.audio == "Dolby Digital Plus 5.1"

      # DDP51 → Dolby Digital Plus 51
      result2 = FileParser.parse("Movie.2024.1080p.DDP51.mkv", standardize: true)
      assert result2.quality.audio == "Dolby Digital Plus 51"

      # EAC3 → Dolby Digital Plus
      result3 = FileParser.parse("Movie.2024.1080p.EAC3.mkv", standardize: true)
      assert result3.quality.audio == "Dolby Digital Plus"
    end

    test "standardizes audio codec - Dolby Digital variations" do
      # DD5.1 → Dolby Digital 5.1
      result1 = FileParser.parse("Movie.2024.1080p.DD5.1.mkv", standardize: true)
      assert result1.quality.audio == "Dolby Digital 5.1"

      # DD51 → Dolby Digital 51
      result2 = FileParser.parse("Movie.2024.1080p.DD51.mkv", standardize: true)
      assert result2.quality.audio == "Dolby Digital 51"

      # AC3 → Dolby Digital
      result3 = FileParser.parse("Movie.2024.1080p.AC3.mkv", standardize: true)
      assert result3.quality.audio == "Dolby Digital"
    end

    test "standardizes audio codec - DTS variations" do
      # DTS-HD.MA → DTS-HD Master Audio
      result1 = FileParser.parse("Movie.2024.1080p.DTS-HD.MA.mkv", standardize: true)
      assert result1.quality.audio == "DTS-HD Master Audio"

      # DTS-HD → DTS-HD High Resolution Audio
      result2 = FileParser.parse("Movie.2024.1080p.DTS-HD.mkv", standardize: true)
      assert result2.quality.audio == "DTS-HD High Resolution Audio"

      # DTS-X → DTS:X
      result3 = FileParser.parse("Movie.2024.1080p.DTS-X.mkv", standardize: true)
      assert result3.quality.audio == "DTS:X"

      # DTS → DTS
      result4 = FileParser.parse("Movie.2024.1080p.DTS.mkv", standardize: true)
      assert result4.quality.audio == "DTS"
    end

    test "standardizes audio codec - Dolby TrueHD and Atmos" do
      # TrueHD → Dolby TrueHD
      result1 = FileParser.parse("Movie.2024.1080p.TrueHD.mkv", standardize: true)
      assert result1.quality.audio == "Dolby TrueHD"

      # TrueHD 7.1 → Dolby TrueHD 7.1
      result2 = FileParser.parse("Movie.2024.1080p.TrueHD.7.1.mkv", standardize: true)
      assert result2.quality.audio == "Dolby TrueHD 7.1"

      # Atmos → Dolby Atmos
      result3 = FileParser.parse("Movie.2024.1080p.Atmos.mkv", standardize: true)
      assert result3.quality.audio == "Dolby Atmos"
    end

    test "standardizes audio codec - AAC variations" do
      # AAC → AAC
      result1 = FileParser.parse("Movie.2024.1080p.AAC.mkv", standardize: true)
      assert result1.quality.audio == "AAC"

      # AAC-LC → AAC-LC
      result2 = FileParser.parse("Movie.2024.1080p.AAC-LC.mkv", standardize: true)
      assert result2.quality.audio == "AAC-LC"
    end

    test "standardizes video codec - H.264/AVC variations" do
      # x264 → H.264/AVC
      result1 = FileParser.parse("Movie.2024.1080p.x264.mkv", standardize: true)
      assert result1.quality.codec == "H.264/AVC"

      # x.264 → H.264/AVC
      result2 = FileParser.parse("Movie.2024.1080p.x.264.mkv", standardize: true)
      assert result2.quality.codec == "H.264/AVC"

      # h264 → H.264/AVC
      result3 = FileParser.parse("Movie.2024.1080p.h264.mkv", standardize: true)
      assert result3.quality.codec == "H.264/AVC"

      # H.264 → H.264/AVC
      result4 = FileParser.parse("Movie.2024.1080p.H.264.mkv", standardize: true)
      assert result4.quality.codec == "H.264/AVC"

      # AVC → H.264/AVC
      result5 = FileParser.parse("Movie.2024.1080p.AVC.mkv", standardize: true)
      assert result5.quality.codec == "H.264/AVC"
    end

    test "standardizes video codec - H.265/HEVC variations" do
      # x265 → H.265/HEVC
      result1 = FileParser.parse("Movie.2024.1080p.x265.mkv", standardize: true)
      assert result1.quality.codec == "H.265/HEVC"

      # x.265 → H.265/HEVC
      result2 = FileParser.parse("Movie.2024.1080p.x.265.mkv", standardize: true)
      assert result2.quality.codec == "H.265/HEVC"

      # h265 → H.265/HEVC
      result3 = FileParser.parse("Movie.2024.1080p.h265.mkv", standardize: true)
      assert result3.quality.codec == "H.265/HEVC"

      # HEVC → H.265/HEVC
      result4 = FileParser.parse("Movie.2024.1080p.HEVC.mkv", standardize: true)
      assert result4.quality.codec == "H.265/HEVC"
    end

    test "standardizes video codec - other codecs" do
      # XviD → XviD
      result1 = FileParser.parse("Movie.2024.480p.XviD.mkv", standardize: true)
      assert result1.quality.codec == "XviD"

      # DivX → DivX
      result2 = FileParser.parse("Movie.2024.480p.DivX.mkv", standardize: true)
      assert result2.quality.codec == "DivX"

      # VP9 → VP9
      result3 = FileParser.parse("Movie.2024.1080p.VP9.mkv", standardize: true)
      assert result3.quality.codec == "VP9"

      # AV1 → AV1
      result4 = FileParser.parse("Movie.2024.1080p.AV1.mkv", standardize: true)
      assert result4.quality.codec == "AV1"

      # NVENC → NVENC
      result5 = FileParser.parse("Movie.2024.1080p.NVENC.mkv", standardize: true)
      assert result5.quality.codec == "NVENC"
    end

    test "standardizes source - Blu-ray variations" do
      # BluRay → Blu-ray
      result1 = FileParser.parse("Movie.2024.1080p.BluRay.mkv", standardize: true)
      assert result1.quality.source == "Blu-ray"

      # BDRip → Blu-ray
      result2 = FileParser.parse("Movie.2024.1080p.BDRip.mkv", standardize: true)
      assert result2.quality.source == "Blu-ray"

      # BRRip → Blu-ray
      result3 = FileParser.parse("Movie.2024.1080p.BRRip.mkv", standardize: true)
      assert result3.quality.source == "Blu-ray"
    end

    test "standardizes source - WEB and other sources" do
      # WEB → WEB
      result1 = FileParser.parse("Movie.2024.1080p.WEB.mkv", standardize: true)
      assert result1.quality.source == "WEB"

      # WEB-DL → WEB-DL
      result2 = FileParser.parse("Movie.2024.1080p.WEB-DL.mkv", standardize: true)
      assert result2.quality.source == "WEB-DL"

      # WEBRip → WEBRip
      result3 = FileParser.parse("Movie.2024.1080p.WEBRip.mkv", standardize: true)
      assert result3.quality.source == "WEBRip"

      # REMUX → Remux
      result4 = FileParser.parse("Movie.2024.1080p.REMUX.mkv", standardize: true)
      assert result4.quality.source == "Remux"

      # HDTV → HDTV
      result5 = FileParser.parse("Show.S01E01.720p.HDTV.mkv", standardize: true)
      assert result5.quality.source == "HDTV"

      # DVD → DVD
      result6 = FileParser.parse("Movie.2024.480p.DVD.mkv", standardize: true)
      assert result6.quality.source == "DVD"

      # DVDRip → DVD
      result7 = FileParser.parse("Movie.2024.480p.DVDRip.mkv", standardize: true)
      assert result7.quality.source == "DVD"
    end

    test "standardizes resolution variations" do
      # 1080p → 1080p (Full HD)
      result1 = FileParser.parse("Movie.2024.1080p.mkv", standardize: true)
      assert result1.quality.resolution == "1080p (Full HD)"

      # 720p → 720p (HD)
      result2 = FileParser.parse("Movie.2024.720p.mkv", standardize: true)
      assert result2.quality.resolution == "720p (HD)"

      # 2160p → 2160p (4K)
      result3 = FileParser.parse("Movie.2024.2160p.mkv", standardize: true)
      assert result3.quality.resolution == "2160p (4K)"

      # 4K → 2160p (4K)
      result4 = FileParser.parse("Movie.2024.4K.mkv", standardize: true)
      assert result4.quality.resolution == "2160p (4K)"

      # UHD → 2160p (4K)
      result5 = FileParser.parse("Movie.2024.UHD.mkv", standardize: true)
      assert result5.quality.resolution == "2160p (4K)"
    end

    test "standardizes HDR format variations" do
      # HDR10+ → HDR10+
      result1 = FileParser.parse("Movie.2024.2160p.HDR10+.mkv", standardize: true)
      assert result1.quality.hdr_format == "HDR10+"

      # HDR10 → HDR10
      result2 = FileParser.parse("Movie.2024.2160p.HDR10.mkv", standardize: true)
      assert result2.quality.hdr_format == "HDR10"

      # DolbyVision → Dolby Vision
      result3 = FileParser.parse("Movie.2024.2160p.DolbyVision.mkv", standardize: true)
      assert result3.quality.hdr_format == "Dolby Vision"

      # DoVi → Dolby Vision
      result4 = FileParser.parse("Movie.2024.2160p.DoVi.mkv", standardize: true)
      assert result4.quality.hdr_format == "Dolby Vision"

      # HDR → HDR
      result5 = FileParser.parse("Movie.2024.2160p.HDR.mkv", standardize: true)
      assert result5.quality.hdr_format == "HDR"
    end

    test "raw mode preserves original values (default behavior)" do
      # Default (standardize: false) should preserve raw values
      result = FileParser.parse("Movie.2024.1080p.BluRay.DDP5.1.x264.mkv")

      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.audio == "DDP5.1"
      assert result.quality.codec == "x264"
    end

    test "standardized mode converts to canonical forms" do
      # With standardize: true, should convert to canonical forms
      result = FileParser.parse("Movie.2024.1080p.BluRay.DDP5.1.x264.mkv", standardize: true)

      assert result.quality.resolution == "1080p (Full HD)"
      assert result.quality.source == "Blu-ray"
      assert result.quality.audio == "Dolby Digital Plus 5.1"
      assert result.quality.codec == "H.264/AVC"
    end

    test "complex real-world example with standardization" do
      result =
        FileParser.parse(
          "The.Dark.Knight.2008.2160p.UHD.BluRay.x265.HDR10+.DTS-HD.MA.7.1-GROUP.mkv",
          standardize: true
        )

      assert result.title == "The Dark Knight"
      assert result.year == 2008
      assert result.quality.resolution == "2160p (4K)"
      assert result.quality.source == "Blu-ray"
      assert result.quality.codec == "H.265/HEVC"
      assert result.quality.hdr_format == "HDR10+"
      assert result.quality.audio == "DTS-HD Master Audio"
      assert result.release_group == "GROUP"
    end

    test "TV show with standardization" do
      result =
        FileParser.parse("Show.Name.S01E05.1080p.WEB-DL.DDP5.1.H.264-GROUP.mkv",
          standardize: true
        )

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [5]
      assert result.quality.resolution == "1080p (Full HD)"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "Dolby Digital Plus 5.1"
      assert result.quality.codec == "H.264/AVC"
      assert result.release_group == "GROUP"
    end

    test "handles unknown codecs gracefully in standardization" do
      # Unknown codec patterns are not extracted, so codec will be nil/absent
      result = FileParser.parse("Movie.2024.1080p.SomeText.mkv", standardize: true)

      # Since "SomeText" doesn't match any codec pattern, it won't be extracted
      assert Map.get(result.quality, :codec) == nil
    end

    test "Black Phone 2 example with standardization" do
      result =
        FileParser.parse(
          "Black Phone 2. 2025 1080P WEB-DL DDP5.1 Atmos. X265. POOLTED.mkv",
          standardize: true
        )

      assert result.type == :movie
      assert result.year == 2025
      assert result.quality.resolution == "1080p (Full HD)"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "Dolby Digital Plus 5.1"
      assert result.quality.codec == "H.265/HEVC"
      assert String.contains?(result.title, "Black Phone 2")
    end

    test "batch standardization test - multiple files" do
      filenames = [
        "Movie1.2024.1080p.BluRay.x264.DDP5.1.mkv",
        "Movie2.2023.2160p.WEB-DL.HEVC.HDR10.DTS-HD.MA.mkv",
        "Show.S01E01.720p.HDTV.h264.AAC.mkv",
        "Film.2022.4K.BDRip.x265.TrueHD.Atmos.mkv"
      ]

      results = Enum.map(filenames, &FileParser.parse(&1, standardize: true))

      # Verify all were standardized
      assert Enum.at(results, 0).quality.codec == "H.264/AVC"
      assert Enum.at(results, 0).quality.audio == "Dolby Digital Plus 5.1"

      assert Enum.at(results, 1).quality.codec == "H.265/HEVC"
      assert Enum.at(results, 1).quality.hdr_format == "HDR10"

      assert Enum.at(results, 2).quality.codec == "H.264/AVC"
      assert Enum.at(results, 2).quality.audio == "AAC"

      assert Enum.at(results, 3).quality.resolution == "2160p (4K)"
      assert Enum.at(results, 3).quality.audio == "Dolby TrueHD"
    end

    test "edge case - empty quality map with standardization" do
      # File with no quality markers
      result = FileParser.parse("RandomFile.mkv", standardize: true)

      assert Quality.empty?(result.quality)
      assert result.type == :unknown
    end

    test "unknown patterns are not extracted" do
      # Unknown source patterns are not extracted, so source will be nil/absent
      result = FileParser.parse("Movie.2024.1080p.RandomText.mkv", standardize: true)

      # Since "RandomText" doesn't match any source pattern, it won't be extracted
      assert Map.get(result.quality, :source) == nil
    end

    test "handles mixed case codec variations" do
      # Mixed case should be normalized correctly
      result1 = FileParser.parse("Movie.2024.1080p.X264.mkv", standardize: true)
      assert result1.quality.codec == "H.264/AVC"

      result2 = FileParser.parse("Movie.2024.1080p.HeVc.mkv", standardize: true)
      assert result2.quality.codec == "H.265/HEVC"
    end

    test "audio codec with different channel configurations" do
      # DD with different channels
      result1 = FileParser.parse("Movie.2024.1080p.DD2.0.mkv", standardize: true)
      assert result1.quality.audio == "Dolby Digital 2.0"

      result2 = FileParser.parse("Movie.2024.1080p.DD7.1.mkv", standardize: true)
      assert result2.quality.audio == "Dolby Digital 7.1"

      # DDP with different channels
      result3 = FileParser.parse("Movie.2024.1080p.DDP2.0.mkv", standardize: true)
      assert result3.quality.audio == "Dolby Digital Plus 2.0"

      result4 = FileParser.parse("Movie.2024.1080p.DDP7.1.mkv", standardize: true)
      assert result4.quality.audio == "Dolby Digital Plus 7.1"
    end

    test "comprehensive torture test with all features" do
      # Kitchen sink: all metadata types with standardization
      result =
        FileParser.parse(
          "Epic.Movie.Title.2024.UHD.BDRip.HEVC.HDR10+.TrueHD.Atmos.7.1-ELITE[rarbg].mkv",
          standardize: true
        )

      assert result.type == :movie
      assert result.title == "Epic Movie Title"
      assert result.year == 2024
      assert result.quality.resolution == "2160p (4K)"
      assert result.quality.source == "Blu-ray"
      assert result.quality.codec == "H.265/HEVC"
      assert result.quality.hdr_format == "HDR10+"
      assert result.quality.audio == "Dolby TrueHD"
      # Release group should still be extracted
      assert result.release_group == "ELITE"
    end
  end

  describe "TV show episode titles in filename - task-177" do
    test "parses TV show without episode title correctly" do
      result = FileParser.parse("The.Witcher.S04E01.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 4
      assert result.episodes == [1]
    end

    test "parses TV show with episode title - should not include episode title in series name" do
      result = FileParser.parse("The.Witcher.S04E01.What.Doesnt.Kill.You.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 4
      assert result.episodes == [1]
    end

    test "parses TV show with long episode title - should not include episode title in series name" do
      result =
        FileParser.parse(
          "The.Witcher.S04E01.What.Doesnt.Kill.You.Makes.You.Stronger.1080p.NF.WEB-DL.DDP5.1.Atmos.H.264-FLUX.mkv"
        )

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 4
      assert result.episodes == [1]
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "DDP5.1"
      assert result.quality.codec == "H.264"
      assert result.release_group == "FLUX"
    end

    test "parses TV show with episode title and quality markers" do
      result = FileParser.parse("The.Witcher.S04E01.Episode.Title.Here.1080p.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 4
      assert result.episodes == [1]
      assert result.quality.resolution == "1080p"
    end

    test "parses TV show with episode title, no additional quality markers" do
      result = FileParser.parse("The.Witcher.S04E01.1080p.WEB-DL.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 4
      assert result.episodes == [1]
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
    end

    test "parses Breaking Bad with episode title" do
      result = FileParser.parse("Breaking.Bad.S01E01.Pilot.mkv")

      assert result.type == :tv_show
      assert result.title == "Breaking Bad"
      assert result.season == 1
      assert result.episodes == [1]
    end

    test "parses Breaking Bad with episode title and quality" do
      result = FileParser.parse("Breaking.Bad.S01E01.Pilot.1080p.BluRay.mkv")

      assert result.type == :tv_show
      assert result.title == "Breaking Bad"
      assert result.season == 1
      assert result.episodes == [1]
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
    end
  end

  describe "TV show with year after episode marker - task-178" do
    test "parses TV show with year in parentheses after episode marker" do
      result = FileParser.parse("The.Witcher.S01E01.(2019).1080p.WEBRIP.HEVC.OPUS2.0.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 1
      assert result.episodes == [1]
      assert result.year == 2019
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEBRIP"
      assert result.quality.codec == "HEVC"
    end

    test "parses TV show with year in brackets after episode marker" do
      result = FileParser.parse("Breaking.Bad.S01E01.[2008].720p.mkv")

      assert result.type == :tv_show
      assert result.title == "Breaking Bad"
      assert result.season == 1
      assert result.episodes == [1]
      assert result.year == 2008
      assert result.quality.resolution == "720p"
    end

    test "parses TV show with year and episode title" do
      result = FileParser.parse("The.Witcher.S01E01.Episode.Title.(2019).1080p.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 1
      assert result.episodes == [1]
      assert result.year == 2019
      assert result.quality.resolution == "1080p"
    end

    test "parses TV show with year but no quality markers" do
      result = FileParser.parse("Show.Name.S02E05.(2020).mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 2
      assert result.episodes == [5]
      assert result.year == 2020
    end

    test "parses TV show with year in parentheses and full quality info" do
      result =
        FileParser.parse("The.Witcher.S01E01.(2019).2160p.NF.WEB-DL.DDP5.1.HDR.H265-GROUP.mkv")

      assert result.type == :tv_show
      assert result.title == "The Witcher"
      assert result.season == 1
      assert result.episodes == [1]
      assert result.year == 2019
      assert result.quality.resolution == "2160p"
      assert result.quality.source == "WEB-DL"
      assert result.quality.audio == "DDP5.1"
      assert result.quality.hdr_format == "HDR"
      assert result.quality.codec == "H265"
      assert result.release_group == "GROUP"
    end

    test "still discards episode titles when year is present" do
      result =
        FileParser.parse("Show.Name.S01E01.Episode.Title.Text.(2021).1080p.WEB-DL.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [1]
      assert result.year == 2021
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
    end
  end
end
