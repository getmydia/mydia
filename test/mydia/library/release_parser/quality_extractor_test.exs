defmodule Mydia.Library.ReleaseParser.QualityExtractorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.QualityExtractor

  describe "extract/2 - raw mode (default)" do
    test "extracts resolution, source, codec, audio from a typical filename" do
      result = ReleaseParser.parse("Movie.2020.1080p.BluRay.x264.DDP5.1.mkv")

      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x264"
      assert result.quality.audio == "DDP5.1"
    end

    test "normalizes resolution casing (1080P → 1080p)" do
      result = ReleaseParser.parse("Movie.2020.1080P.mkv")
      assert result.quality.resolution == "1080p"
    end

    test "pulls plain resolution out of a compound token (2160p-NVENC)" do
      result = ReleaseParser.parse("Movie (2020) BDRip 2160p-NVENC 10 bit.mkv")
      assert result.quality.resolution == "2160p"
    end

    test "rejoins WEB into WEB-DL when followed by DL" do
      result = ReleaseParser.parse("Show.S01E01.1080p.WEB-DL.mkv")
      assert result.quality.source == "WEB-DL"
    end

    test "rejoins DTS-HD.MA across split tokens" do
      result = ReleaseParser.parse("Movie.2020.1080p.DTS-HD.MA.mkv")
      assert result.quality.audio == "DTS-HD.MA"
    end

    test "rejoins DTS-X across split tokens" do
      result = ReleaseParser.parse("Movie.2020.1080p.DTS-X.mkv")
      assert result.quality.audio == "DTS-X"
    end
  end

  describe "extract/2 - standardize mode" do
    test "codec canonicalization" do
      result = ReleaseParser.parse("Movie.2020.1080p.x264.mkv", standardize: true)
      assert result.quality.codec == "H.264/AVC"

      result = ReleaseParser.parse("Movie.2020.1080p.x265.mkv", standardize: true)
      assert result.quality.codec == "H.265/HEVC"
    end

    test "audio canonicalization" do
      result = ReleaseParser.parse("Movie.2020.1080p.DDP5.1.mkv", standardize: true)
      assert result.quality.audio == "Dolby Digital Plus 5.1"

      result = ReleaseParser.parse("Movie.2020.1080p.AC3.mkv", standardize: true)
      assert result.quality.audio == "Dolby Digital"
    end

    test "source canonicalization" do
      result = ReleaseParser.parse("Movie.2020.1080p.BluRay.mkv", standardize: true)
      assert result.quality.source == "Blu-ray"
    end

    test "resolution canonicalization" do
      result = ReleaseParser.parse("Movie.2020.2160p.mkv", standardize: true)
      assert result.quality.resolution == "2160p (4K)"

      result = ReleaseParser.parse("Movie.2020.4K.mkv", standardize: true)
      assert result.quality.resolution == "2160p (4K)"
    end

    test "Dolby Vision detection" do
      result = ReleaseParser.parse("Movie.2020.2160p.DoVi.mkv", standardize: true)
      assert result.quality.dolby_vision
      assert result.quality.hdr_format == nil
    end
  end

  describe "extract/2 - direct from resolver result" do
    test "accepts resolver result map with all_tokens" do
      input = "Movie.2020.1080p.AAC.mkv"

      tokens = Mydia.Library.ReleaseParser.Tokenizer.tokenize(input)
      anchors = Mydia.Library.ReleaseParser.Tokenizer.anchor_positions(input)
      classified = Mydia.Library.ReleaseParser.Classifier.classify(tokens, anchors)
      resolver_result = Mydia.Library.ReleaseParser.Resolver.resolve(classified, nil)

      quality = QualityExtractor.extract(resolver_result, [])

      assert quality.resolution == "1080p"
      assert quality.audio == "AAC"
    end

    test "accepts plain quality_tokens list (legacy shape)" do
      # No all_tokens — should still return a Quality{} with at least
      # the basic values intact.
      quality = QualityExtractor.extract([], [])

      assert quality.resolution == nil
      assert quality.source == nil
      assert quality.audio == nil
    end
  end
end
