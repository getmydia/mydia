defmodule Mydia.Indexers.QualityParserTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.QualityParser
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.Quality

  describe "parse/1" do
    test "parses complete quality information" do
      title = "Movie.Name.2023.1080p.BluRay.x264.DTS-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "1080p"
      assert quality.source == "BluRay"
      assert quality.codec == "x264"
      assert quality.audio == "DTS"
      assert quality.hdr_format == nil
      refute quality.dolby_vision
      assert quality.proper == false
      assert quality.repack == false
    end

    test "parses HDR content" do
      title = "Movie.2023.2160p.WEB-DL.HDR.H.265.AAC-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "2160p"
      assert quality.source == "WEB-DL"
      assert quality.codec == "H.265"
      assert quality.audio == "AAC"
      assert quality.hdr_format == :hdr10
    end

    test "parses PROPER releases" do
      title = "Show.S01E01.PROPER.1080p.WEB-DL.x264"
      quality = QualityParser.parse(title)

      assert quality.proper == true
      assert quality.resolution == "1080p"
    end

    test "parses REPACK releases" do
      title = "Movie.2023.REPACK.720p.BluRay.x264"
      quality = QualityParser.parse(title)

      assert quality.repack == true
      assert quality.resolution == "720p"
    end

    test "handles missing quality information" do
      title = "Some.Random.File.Name"
      quality = QualityParser.parse(title)

      assert quality.resolution == nil
      assert quality.source == nil
      assert quality.codec == nil
      assert quality.audio == nil
      assert quality.hdr_format == nil
      refute quality.dolby_vision
      assert quality.proper == false
      assert quality.repack == false
    end
  end

  describe "parse/1 delegates to ReleaseParser" do
    for title <- [
          "Fake.Movie.2020.1080p.BluRay.x264-GRP",
          "Fake.Show.S01E01.PROPER.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-GRP",
          "Fake.Movie.2020.HDTS.x264-GRP",
          "Some.Web.Show.2024.1080p.x264-GRP"
        ] do
      test "matches ReleaseParser for #{title}" do
        assert QualityParser.parse(unquote(title)) ==
                 ReleaseParser.parse(unquote(title)).quality
      end
    end

    test "a slash in an indexer title is not a path separator" do
      # ReleaseParser takes Path.basename of its input, so a "/" would drop
      # every quality token before it.
      quality = QualityParser.parse("Fake.Movie.2020.2160p.BluRay/x265-GRP")

      assert {quality.resolution, quality.source, quality.codec} ==
               {"2160p", "BluRay", "x265"}
    end
  end

  describe "effective_resolution/1" do
    test "returns the detected resolution when the title carries one" do
      assert QualityParser.effective_resolution(QualityParser.parse("Movie.1080p.BluRay")) ==
               "1080p"
    end

    test "assumes 360p when the title carries no resolution token" do
      # An untagged release is SD in practice. Scoring it as "unknown" made it
      # rank above an honestly-labelled 720p, which is how a 360p XviD beat a
      # 720p x265 for a monitored episode.
      quality =
        QualityParser.parse("Example.Show.2024.S02E01.Episode.Title.XviD-GRP[site.to].avi")

      assert quality.resolution == nil, "parse/1 must stay honest about what it detected"
      assert QualityParser.effective_resolution(quality) == "360p"
    end

    test "assumes 360p for a nil quality" do
      assert QualityParser.effective_resolution(nil) == "360p"
    end

    test "parse/1 is left untouched so renamed files never get a false 360p tag" do
      # media_import.ex feeds parse/1 into FileNamer. A resolution invented
      # here would be written into the filename on disk.
      assert QualityParser.parse("Movie.BluRay.x264").resolution == nil
    end
  end

  describe "has_hdr?/1" do
    test "detects HDR in title" do
      assert QualityParser.has_hdr?("Movie.2160p.WEB-DL.HDR.x265")
    end

    test "detects Dolby Vision" do
      assert QualityParser.has_hdr?("Movie.2160p.WEB-DL.Dolby-Vision.x265")
      assert QualityParser.has_hdr?("Movie.2160p.WEB-DL.DV.x265")
    end

    test "returns false when no HDR" do
      refute QualityParser.has_hdr?("Movie.1080p.BluRay.x264")
    end

    test "is case insensitive" do
      assert QualityParser.has_hdr?("MOVIE.HDR.X265")
    end
  end

  describe "quality_score/1" do
    test "scores 2160p BluRay with Dolby Vision highest" do
      quality =
        Quality.new(
          resolution: "2160p",
          source: "BluRay",
          codec: "x265",
          audio: "TrueHD Atmos",
          hdr_format: :hdr10,
          dolby_vision: true,
          proper: false,
          repack: false
        )

      score = QualityParser.quality_score(quality)
      # 2160p(1000) + BluRay(450) + x265(150) + TrueHD Atmos(200) + DolbyVision(100) = 1900
      assert score == 1900
    end

    test "scores 2160p BluRay with HDR10" do
      quality =
        Quality.new(
          resolution: "2160p",
          source: "BluRay",
          codec: "x265",
          audio: nil,
          hdr_format: :hdr10,
          proper: false,
          repack: false
        )

      score = QualityParser.quality_score(quality)
      # 2160p(1000) + BluRay(450) + x265(150) + HDR10(60) = 1660
      assert score == 1660
    end

    test "scores 1080p WEB-DL x264 appropriately" do
      quality =
        Quality.new(
          resolution: "1080p",
          source: "WEB-DL",
          codec: "x264",
          audio: nil,
          proper: false,
          repack: false
        )

      score = QualityParser.quality_score(quality)
      # 1080p(800) + WEB-DL(400) + x264(100) = 1300
      assert score == 1300
    end

    test "adds bonus for PROPER (25 points)" do
      quality_without =
        Quality.new(
          resolution: "1080p",
          source: "BluRay",
          codec: "x264",
          audio: nil,
          proper: false,
          repack: false
        )

      quality_with = %{quality_without | proper: true}

      assert QualityParser.quality_score(quality_with) ==
               QualityParser.quality_score(quality_without) + 25
    end

    test "adds bonus for REPACK (15 points)" do
      quality_without =
        Quality.new(
          resolution: "1080p",
          source: "BluRay",
          codec: "x264",
          audio: nil,
          proper: false,
          repack: false
        )

      quality_with = %{quality_without | repack: true}

      assert QualityParser.quality_score(quality_with) ==
               QualityParser.quality_score(quality_without) + 15
    end

    test "handles nil values gracefully" do
      quality =
        Quality.new(
          resolution: nil,
          source: nil,
          codec: nil,
          audio: nil,
          proper: false,
          repack: false
        )

      assert QualityParser.quality_score(quality) == 0
    end

    test "scores CAM releases lowest" do
      quality =
        Quality.new(
          resolution: "480p",
          source: "CAM",
          codec: "XviD",
          audio: nil,
          proper: false,
          repack: false
        )

      score = QualityParser.quality_score(quality)
      assert score < 500
    end

    test "scores PDTV with SDTV and Workprint with CAM" do
      base = Quality.new(resolution: "480p", codec: "XviD")

      assert QualityParser.quality_score(%{base | source: "PDTV"}) ==
               QualityParser.quality_score(%{base | source: "SDTV"})

      assert QualityParser.quality_score(%{base | source: "Workprint"}) ==
               QualityParser.quality_score(%{base | source: "CAM"})
    end
  end

  describe "quality_score/1 with channel-carrying audio" do
    test "channels do not change the audio tier" do
      base = Quality.new(resolution: "1080p", source: "WEB-DL", codec: "x264")

      assert QualityParser.quality_score(%{base | audio: "DD+ 5.1"}) ==
               QualityParser.quality_score(%{base | audio: "DD+"})

      assert QualityParser.quality_score(%{base | audio: "TrueHD Atmos 7.1"}) -
               QualityParser.quality_score(base) == 200
    end

    test "every tier keeps its score with channels attached" do
      base = Quality.new(resolution: "1080p", source: "BluRay", codec: "x264")
      score = &QualityParser.quality_score(%{base | audio: &1})

      for codec <- ["TrueHD", "DTS-HD MA", "DTS-HD", "DTS:X", "DTS", "AC3", "AAC", "FLAC"] do
        assert score.(codec <> " 5.1") == score.(codec), "#{codec} 5.1 scored off-tier"
      end
    end

    test "a bare Atmos label scores no audio tier" do
      base = Quality.new(resolution: "1080p", source: "WEB-DL", codec: "x264")

      assert QualityParser.quality_score(%{base | audio: "Atmos"}) ==
               QualityParser.quality_score(base)
    end
  end

  describe "real world examples" do
    test "parses typical movie release with DTS-HD MA" do
      title = "The.Movie.2023.1080p.BluRay.x264.DTS-HD.MA.5.1-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "1080p"
      assert quality.source == "BluRay"
      assert quality.codec == "x264"
      assert quality.audio == "DTS-HD MA 5.1"
      assert quality.hdr_format == nil
      refute quality.dolby_vision
    end

    test "parses 4K Dolby Vision release with DD+" do
      # DD+ Atmos is still DD+ as the base codec (Atmos is an extension)
      title = "Movie.Name.2023.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "2160p"
      assert quality.source == "WEB-DL"
      assert quality.codec == "H.265"
      assert quality.audio == "DD+ 5.1"
      assert quality.dolby_vision
      assert quality.hdr_format == :hdr10
    end

    test "parses 4K REMUX with TrueHD Atmos" do
      title = "Movie.2023.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos.7.1-FraMeSToR"
      quality = QualityParser.parse(title)

      assert quality.resolution == "2160p"
      assert quality.source == "REMUX"
      assert quality.codec == "H.265"
      assert quality.audio == "TrueHD Atmos 7.1"
      assert quality.dolby_vision
      assert quality.hdr_format == :hdr10
    end

    test "parses TV episode release" do
      title = "Show.Name.S01E05.Episode.Title.1080p.HDTV.x264.AAC-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "1080p"
      assert quality.source == "HDTV"
      assert quality.codec == "x264"
      assert quality.audio == "AAC"
    end

    test "parses PROPER REPACK release" do
      title = "Movie.2023.PROPER.REPACK.1080p.BluRay.x264-Group"
      quality = QualityParser.parse(title)

      assert quality.proper == true
      assert quality.repack == true
      assert quality.resolution == "1080p"
      assert quality.source == "BluRay"
    end

    test "parses HDR10+ release" do
      title = "Movie.2023.2160p.UHD.BluRay.HDR10Plus.HEVC.DTS-HD.MA.5.1-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "2160p"
      assert quality.source == "BluRay"
      assert quality.hdr_format == :hdr10_plus
      assert quality.audio == "DTS-HD MA 5.1"
    end
  end

  describe "canonical HDR parsing" do
    test "DV in a release name sets dolby_vision, not hdr_format" do
      quality = QualityParser.parse("Movie.2024.2160p.BluRay.DV.HDR10.x265-GRP")
      assert quality.dolby_vision
      assert quality.hdr_format == :hdr10
    end

    test "a bare HDR token maps to :hdr10" do
      assert QualityParser.parse("Movie.2024.2160p.HDR.x265").hdr_format == :hdr10
    end

    test "HDR10+ maps to :hdr10_plus" do
      assert QualityParser.parse("Movie.2024.2160p.HDR10+.x265").hdr_format == :hdr10_plus
    end

    test "an SDR release has neither" do
      quality = QualityParser.parse("Movie.2024.1080p.BluRay.x264-GRP")
      assert quality.hdr_format == nil
      refute quality.dolby_vision
    end
  end
end
