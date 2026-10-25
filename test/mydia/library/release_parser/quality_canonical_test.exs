defmodule Mydia.Library.ReleaseParser.QualityCanonicalTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser

  defp q(title), do: ReleaseParser.parse(title).quality

  describe "canonical labels" do
    test "BDRip and BRRip fold into BluRay" do
      assert q("Fake.Movie.2020.1080p.BDRip.x264-GRP").source == "BluRay"
      assert q("Fake.Movie.2020.720p.BRRip.x264-GRP").source == "BluRay"
      assert q("Fake.Movie.2020.1080p.Bluray.x264-GRP").source == "BluRay"
    end

    test "bare WEB reads as WEB-DL and WEB-Rip as WEBRip" do
      assert q("Fake.Show.S01E01.1080p.WEB.H264-GRP").source == "WEB-DL"
      assert q("Fake.Show.S01E01.1080p.WEB-Rip.x264-GRP").source == "WEBRip"
    end

    test "resolution aliases normalise" do
      assert q("Fake.Movie.2020.4K.UHD.BluRay.x265-GRP").resolution == "2160p"
      assert q("Fake.Movie.2020.1440p.WEB-DL.x264-GRP").resolution == "1080p"
      assert q("Fake.Show.S01E01.1080i.HDTV.MPEG2-GRP").resolution == "1080p"
    end

    test "codec spellings normalise, keeping the encoder/format split" do
      assert q("Fake.Movie.2020.1080p.BluRay.REMUX.AVC-GRP").codec == "H.264"
      assert q("Fake.Movie.2020.2160p.WEB-DL.HEVC-GRP").codec == "H.265"
      assert q("Fake.Movie.2020.1080p.WEB-DL.H264-GRP").codec == "H.264"
      assert q("Fake.Movie.2020.1080p.BluRay.x264-GRP").codec == "x264"
    end

    test "audio uses the scorer's labels with channels" do
      assert q("Fake.Movie.2020.1080p.AMZN.WEB-DL.DDP2.0.H.264-GRP").audio == "DD+ 2.0"
      assert q("Fake.Movie.2020.1080p.BluRay.DD5.1.x264-GRP").audio == "AC3 5.1"
      assert q("Fake.Movie.2020.1080p.BluRay.DTS-HD.MA.5.1.x264-GRP").audio == "DTS-HD MA 5.1"
      assert q("Fake.Movie.2020.1080p.BluRay.DTS-X.x264-GRP").audio == "DTS:X"
      assert q("Fake.Movie.2020.1080p.BluRay.TrueHD.7.1.x264-GRP").audio == "TrueHD 7.1"
    end
  end

  describe "standardize: true is unchanged for display" do
    test "projects canonical values to display strings" do
      std =
        ReleaseParser.parse("Fake.Movie.2020.2160p.BDRip.DDP5.1.HEVC-GRP", standardize: true).quality

      assert std.source == "Blu-ray"
      assert std.audio == "Dolby Digital Plus 5.1"
      assert std.codec == "H.265/HEVC"
      assert std.resolution == "2160p (4K)"
    end
  end
end
