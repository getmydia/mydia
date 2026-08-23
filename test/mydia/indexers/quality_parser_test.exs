defmodule Mydia.Indexers.QualityParserTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.QualityParser
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

  describe "extract_resolution/1" do
    test "extracts 2160p resolution" do
      assert QualityParser.extract_resolution("Movie.2160p.BluRay") == "2160p"
      assert QualityParser.extract_resolution("Movie.4K.BluRay") == "2160p"
    end

    test "extracts 1080p resolution" do
      assert QualityParser.extract_resolution("Movie.1080p.BluRay") == "1080p"
    end

    test "extracts 720p resolution" do
      assert QualityParser.extract_resolution("Movie.720p.WEB-DL") == "720p"
    end

    test "extracts 480p resolution" do
      assert QualityParser.extract_resolution("Movie.480p.DVDRip") == "480p"
    end

    test "returns nil when no resolution found" do
      assert QualityParser.extract_resolution("Movie.BluRay.x264") == nil
    end

    test "is case insensitive" do
      assert QualityParser.extract_resolution("MOVIE.1080P.BLURAY") == "1080p"
    end
  end

  describe "extract_source/1" do
    test "extracts BluRay source" do
      assert QualityParser.extract_source("Movie.1080p.BluRay.x264") == "BluRay"
      assert QualityParser.extract_source("Movie.1080p.Blu-Ray.x264") == "BluRay"
      assert QualityParser.extract_source("Movie.1080p.BDRip.x264") == "BluRay"
      assert QualityParser.extract_source("Movie.1080p.BRRip.x264") == "BluRay"
    end

    test "extracts WEB-DL source" do
      assert QualityParser.extract_source("Movie.1080p.WEB-DL.x264") == "WEB-DL"
      assert QualityParser.extract_source("Movie.1080p.WEBDL.x264") == "WEB-DL"
    end

    test "extracts WEBRip source" do
      assert QualityParser.extract_source("Movie.1080p.WEBRip.x264") == "WEBRip"
      assert QualityParser.extract_source("Movie.1080p.WEB-Rip.x264") == "WEBRip"
    end

    test "extracts HDTV source" do
      assert QualityParser.extract_source("Show.S01E01.HDTV.x264") == "HDTV"
    end

    test "extracts DVDRip source" do
      assert QualityParser.extract_source("Movie.DVDRip.x264") == "DVDRip"
    end

    test "returns nil when no source found" do
      assert QualityParser.extract_source("Movie.1080p.x264") == nil
    end

    test "is case insensitive" do
      assert QualityParser.extract_source("MOVIE.BLURAY.X264") == "BluRay"
    end
  end

  describe "extract_codec/1" do
    test "extracts x264 codec" do
      assert QualityParser.extract_codec("Movie.1080p.BluRay.x264") == "x264"
      assert QualityParser.extract_codec("Movie.1080p.BluRay.x.264") == "x264"
    end

    test "extracts x265 codec" do
      assert QualityParser.extract_codec("Movie.2160p.WEB-DL.x265") == "x265"
      assert QualityParser.extract_codec("Movie.2160p.WEB-DL.HEVC") == "x265"
    end

    test "extracts H.264 codec" do
      assert QualityParser.extract_codec("Movie.1080p.BluRay.H.264") == "H.264"
      assert QualityParser.extract_codec("Movie.1080p.BluRay.AVC") == "H.264"
    end

    test "extracts H.265 codec" do
      assert QualityParser.extract_codec("Movie.2160p.WEB-DL.H.265") == "H.265"
    end

    test "extracts other codecs" do
      assert QualityParser.extract_codec("Movie.XviD") == "XviD"
      assert QualityParser.extract_codec("Movie.DivX") == "DivX"
      assert QualityParser.extract_codec("Movie.VP9") == "VP9"
      assert QualityParser.extract_codec("Movie.AV1") == "AV1"
    end

    test "returns nil when no codec found" do
      assert QualityParser.extract_codec("Movie.1080p.BluRay") == nil
    end

    test "is case insensitive" do
      assert QualityParser.extract_codec("MOVIE.X264") == "x264"
    end
  end

  describe "extract_audio/1" do
    test "extracts DTS audio" do
      assert QualityParser.extract_audio("Movie.1080p.BluRay.DTS") == "DTS"
    end

    test "extracts DTS-HD audio" do
      assert QualityParser.extract_audio("Movie.1080p.BluRay.DTS-HD") == "DTS-HD"
    end

    test "extracts TrueHD audio" do
      assert QualityParser.extract_audio("Movie.1080p.BluRay.TrueHD") == "TrueHD"
    end

    test "extracts AAC audio" do
      assert QualityParser.extract_audio("Movie.1080p.WEB-DL.AAC") == "AAC"
    end

    test "extracts AC3 audio" do
      assert QualityParser.extract_audio("Movie.1080p.BluRay.AC3") == "AC3"
      # DD5.1 is detected as AC3 (Dolby Digital)
      assert QualityParser.extract_audio("Movie.1080p.BluRay.DD5.1") == "AC3"
    end

    test "extracts DD+ (Dolby Digital Plus) audio" do
      assert QualityParser.extract_audio("Movie.1080p.WEB-DL.DDP5.1") == "DD+"
      assert QualityParser.extract_audio("Movie.1080p.WEB-DL.DD+") == "DD+"
      assert QualityParser.extract_audio("Movie.1080p.WEB-DL.E-AC3") == "DD+"
    end

    test "extracts TrueHD Atmos audio" do
      # TrueHD Atmos is a specific lossless format with object audio
      assert QualityParser.extract_audio("Movie.TrueHD.Atmos") == "TrueHD Atmos"
      assert QualityParser.extract_audio("Movie.TrueHD.7.1.Atmos") == "TrueHD Atmos"
    end

    test "extracts DTS-HD MA audio" do
      assert QualityParser.extract_audio("Movie.DTS-HD.MA.5.1") == "DTS-HD MA"
      assert QualityParser.extract_audio("Movie.DTS-HD.MA") == "DTS-HD MA"
    end

    test "extracts other audio codecs" do
      assert QualityParser.extract_audio("Movie.MP3") == "MP3"
      assert QualityParser.extract_audio("Movie.FLAC") == "FLAC"
      assert QualityParser.extract_audio("Movie.Opus") == "Opus"
      # Note: Plain "Atmos" without TrueHD is ambiguous - DD+ Atmos is still DD+
    end

    test "returns nil when no audio codec found" do
      assert QualityParser.extract_audio("Movie.1080p.BluRay.x264") == nil
    end

    test "is case insensitive" do
      assert QualityParser.extract_audio("MOVIE.DTS") == "DTS"
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

  describe "has_proper?/1" do
    test "detects PROPER tag" do
      assert QualityParser.has_proper?("Movie.PROPER.1080p.BluRay")
    end

    test "returns false when no PROPER tag" do
      refute QualityParser.has_proper?("Movie.1080p.BluRay")
    end

    test "is case insensitive" do
      assert QualityParser.has_proper?("movie.proper.1080p")
    end

    test "only matches whole word PROPER" do
      refute QualityParser.has_proper?("Movie.Improperly.Named")
    end
  end

  describe "has_repack?/1" do
    test "detects REPACK tag" do
      assert QualityParser.has_repack?("Movie.REPACK.1080p.BluRay")
    end

    test "returns false when no REPACK tag" do
      refute QualityParser.has_repack?("Movie.1080p.BluRay")
    end

    test "is case insensitive" do
      assert QualityParser.has_repack?("movie.repack.1080p")
    end

    test "only matches whole word REPACK" do
      refute QualityParser.has_repack?("Movie.Repacker.Name")
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
  end

  describe "real world examples" do
    test "parses typical movie release with DTS-HD MA" do
      title = "The.Movie.2023.1080p.BluRay.x264.DTS-HD.MA.5.1-Group"
      quality = QualityParser.parse(title)

      assert quality.resolution == "1080p"
      assert quality.source == "BluRay"
      assert quality.codec == "x264"
      assert quality.audio == "DTS-HD MA"
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
      assert quality.audio == "DD+"
      assert quality.dolby_vision
      assert quality.hdr_format == :hdr10
    end

    test "parses 4K REMUX with TrueHD Atmos" do
      title = "Movie.2023.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos.7.1-FraMeSToR"
      quality = QualityParser.parse(title)

      assert quality.resolution == "2160p"
      assert quality.source == "REMUX"
      assert quality.codec == "x265"
      assert quality.audio == "TrueHD Atmos"
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
      assert quality.audio == "DTS-HD MA"
    end
  end

  describe "extract_source/1 regression: unanchored short tokens" do
    test "ordinary words containing cam-tier letter pairs are not cam-tier" do
      alias Mydia.Quality.Sources

      for title <- [
            "Ghosts.of.Mars.2001.1080p.x264-GRP",
            "The.Watchmen.2009.2160p.HDR.x265",
            "Scream.VI.2023.1080p.x265-RARBG",
            "Cameron.Diaz.Doc.2020.1080p.x264",
            "Lights.Out.2016.1080p.x264"
          ] do
        refute Sources.cam_tier?(QualityParser.extract_source(title)),
               "#{title} must not be classified cam-tier"
      end
    end

    test "real telesync releases are still detected" do
      assert QualityParser.extract_source("The.Odyssey.2026.1080p.TELESYNC.HEVC.AAC2.0") ==
               "Telesync"

      assert QualityParser.extract_source("Movie.2026.HDTS.x264") == "Telesync"
      assert QualityParser.extract_source("Movie.2026.HDCAM.x264") == "CAM"
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

    test "the first base token wins when a title carries two distinct bases" do
      # A bare HDR token (:hdr10) precedes an HDR10+ token here; extract_hdr/1
      # must keep the first base found, not the last, or a release that opens
      # with a weaker HDR claim would silently overwrite a stronger one found
      # later (or vice versa) depending on token order alone.
      assert QualityParser.extract_hdr("Movie.2024.2160p.HDR.HDR10+.x265") == {:hdr10, false}
    end

    test "an SDR release has neither" do
      quality = QualityParser.parse("Movie.2024.1080p.BluRay.x264-GRP")
      assert quality.hdr_format == nil
      refute quality.dolby_vision
    end
  end
end
