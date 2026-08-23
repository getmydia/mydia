defmodule Mydia.Library.FileNamerTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.FileNamer

  describe "generate_movie_filename/3" do
    test "generates TRaSH-compatible filename for movie" do
      media_item = %{title: "The Matrix", year: 1999}

      quality_info = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        hdr_format: nil,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "The.Matrix.1999.1080p.BluRay.x264.DTS-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result == "The Matrix (1999) [BluRay-1080p] [DTS] [x264]-GROUP.mkv"
    end

    test "handles movies with special characters in title" do
      media_item = %{title: "Law & Order: The Movie", year: 2020}

      quality_info = %{
        resolution: "720p",
        source: "WEB-DL",
        codec: "x265",
        audio: "AAC",
        hdr_format: nil,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Law.and.Order.The.Movie.2020.720p.WEB-DL.x265.AAC-GROUP.mp4"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result == "Law and Order - The Movie (2020) [WEB-DL-720p] [AAC] [x265]-GROUP.mp4"
    end

    test "handles PROPER releases" do
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr_format: nil,
        dolby_vision: false,
        proper: true,
        repack: false
      }

      original = "Test.Movie.2023.PROPER.1080p.BluRay.x264-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result == "Test Movie (2023) [BluRay-1080p-Proper] [x264]-GROUP.mkv"
    end

    test "handles REPACK releases" do
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "x265",
        audio: "DTS",
        hdr_format: :hdr10,
        dolby_vision: false,
        proper: false,
        repack: true
      }

      original = "Test.Movie.2023.REPACK.2160p.WEB-DL.HDR.x265.DTS-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result == "Test Movie (2023) [WEB-DL-2160p-Repack] [DTS] [HDR10] [x265]-GROUP.mkv"
    end
  end

  describe "generate_episode_filename/4" do
    test "generates TRaSH-compatible filename for TV episode" do
      media_item = %{title: "Breaking Bad", year: 2008}
      episode = %{season_number: 1, episode_number: 1, title: "Pilot"}

      quality_info = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr_format: nil,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Breaking.Bad.S01E01.1080p.BluRay.x264-GROUP.mkv"

      result = FileNamer.generate_episode_filename(media_item, episode, quality_info, original)

      assert result == "Breaking Bad (2008) - S01E01 - Pilot [BluRay-1080p] [x264]-GROUP.mkv"
    end

    test "handles TV episode with audio codec" do
      media_item = %{title: "Game of Thrones", year: 2011}
      episode = %{season_number: 8, episode_number: 6, title: "The Iron Throne"}

      quality_info = %{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "H.265",
        audio: "Atmos",
        hdr_format: :hdr10,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Game.of.Thrones.S08E06.2160p.WEB-DL.HDR.H.265.Atmos-GROUP.mkv"

      result = FileNamer.generate_episode_filename(media_item, episode, quality_info, original)

      assert result ==
               "Game of Thrones (2011) - S08E06 - The Iron Throne [WEB-DL-2160p] [Atmos] [HDR10] [H.265]-GROUP.mkv"
    end

    test "handles TV episode without year" do
      media_item = %{title: "New Show", year: nil}
      episode = %{season_number: 1, episode_number: 5, title: "Episode Five"}

      quality_info = %{
        resolution: "720p",
        source: "HDTV",
        codec: "x264",
        audio: "AAC",
        hdr_format: nil,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "New.Show.S01E05.720p.HDTV.x264.AAC-GROUP.mkv"

      result = FileNamer.generate_episode_filename(media_item, episode, quality_info, original)

      assert result == "New Show - S01E05 - Episode Five [HDTV-720p] [AAC] [x264]-GROUP.mkv"
    end
  end

  describe "HDR tag" do
    test "renders the specific format, not a flat [HDR]" do
      # build_hdr_tag/1 used to emit a flat "[HDR]" for every format while
      # the module's own docstring promised something like "[DV HDR10]".
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "2160p",
        source: "BluRay",
        codec: "x265",
        audio: nil,
        hdr_format: :hdr10,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Test.Movie.2023.2160p.BluRay.HDR.x265-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result =~ "[HDR10]"
      refute result =~ "[HDR]]"
    end

    test "renders HDR10+ distinctly from plain HDR10" do
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "2160p",
        source: "BluRay",
        codec: "x265",
        audio: nil,
        hdr_format: :hdr10_plus,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Test.Movie.2023.2160p.BluRay.HDR10Plus.x265-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result =~ "[HDR10+]"
    end

    test "renders HLG" do
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "2160p",
        source: "BluRay",
        codec: "x265",
        audio: nil,
        hdr_format: :hlg,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Test.Movie.2023.2160p.BluRay.HLG.x265-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result =~ "[HLG]"
    end

    test "a Dolby Vision profile 5 file (hdr_format nil) still gets an HDR tag" do
      # REGRESSION: profile 5 has hdr_format == nil by design because it has
      # no HDR10-compatible base layer. Deciding SDR by testing hdr_format
      # for nil drops the tag from exactly the files that most need it.
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "2160p",
        source: "BluRay",
        codec: "x265",
        audio: nil,
        hdr_format: nil,
        dolby_vision: true,
        proper: false,
        repack: false
      }

      original = "Test.Movie.2023.2160p.BluRay.DV.x265-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      assert result =~ "[Dolby Vision]"
    end

    test "an SDR file gets no HDR tag" do
      media_item = %{title: "Test Movie", year: 2023}

      quality_info = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr_format: nil,
        dolby_vision: false,
        proper: false,
        repack: false
      }

      original = "Test.Movie.2023.1080p.BluRay.x264-GROUP.mkv"

      result = FileNamer.generate_movie_filename(media_item, quality_info, original)

      refute result =~ "HDR"
      refute result =~ "Dolby Vision"
    end
  end

  describe "sanitize_title/1" do
    test "replaces colons with dashes" do
      assert FileNamer.sanitize_title("Star Wars: Episode IV") == "Star Wars - Episode IV"
    end

    test "replaces ampersands with 'and'" do
      assert FileNamer.sanitize_title("Law & Order") == "Law and Order"
    end

    test "removes question marks" do
      assert FileNamer.sanitize_title("Where Are You?") == "Where Are You"
    end

    test "handles multiple special characters" do
      title = "The Good, the Bad & the Ugly: Director's Cut?"
      result = FileNamer.sanitize_title(title)
      assert result == "The Good, the Bad and the Ugly - Director's Cut"
    end

    test "removes multiple spaces" do
      assert FileNamer.sanitize_title("Too    Many    Spaces") == "Too Many Spaces"
    end
  end
end
