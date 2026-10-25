defmodule Mydia.Library.ReleaseParser.QualityAudioTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser

  defp audio(title), do: ReleaseParser.parse(title).quality.audio

  test "fused and spaced channel forms" do
    assert audio("Fake.Movie.2020.1080p.WEB-DL.AAC5.1.H.264-GRP") == "AAC 5.1"
    assert audio("Fake Movie 2020 1080p WEB-DL AAC2 0 H 264-GRP") == "AAC 2.0"
    assert audio("Fake Movie 2020 1080p BluRay DD 5 1 x264-GRP") == "AC3 5.1"
    assert audio("Fake.Movie.2020.1080p.WEB-DL.AAC.2.0.H.264-GRP") == "AAC 2.0"
  end

  test "glued DD+ channels" do
    assert audio("Fake.Movie.2020.1080p.WEB-DL.DD+5.1.H.264-GRP") == "DD+ 5.1"
  end

  test "Atmos" do
    assert audio("Fake.Movie.2020.1080p.BluRay.TrueHD.7.1.Atmos.x264-GRP") == "TrueHD Atmos 7.1"
    assert audio("Fake.Movie.2020.2160p.BluRay.Atmos.TrueHD.7.1.x265-GRP") == "TrueHD Atmos 7.1"
    assert audio("Fake.Movie.2020.2160p.WEB-DL.DDP5.1.Atmos.H.265-GRP") == "DD+ 5.1"
  end

  test "E-AC-3 spellings" do
    assert audio("Fake.Show.S01E01.1080p.WEB-DL.EAC3.H.264-GRP") == "DD+"
    assert audio("Fake.Show.S01E01.1080p.WEB-DL.E-AC-3.H.264-GRP") == "DD+"
    assert audio("Fake.Show.S01E01.1080p.WEB-DL.E-AC3.H.264-GRP") == "DD+"
  end

  test "lossy web codecs" do
    assert audio("Fake.Movie.2020.1080p.WEBRip.VP9.Vorbis-GRP") == "Vorbis"
    assert audio("Fake.Movie.2020.1080p.WEBRip.VP9.Opus-GRP") == "Opus"
  end

  test "HDTS is not DTS audio" do
    assert audio("Fake.Movie.2020.HDTS.x264-GRP") == nil
  end

  test "an audio word in the title is not a track" do
    assert audio("Fake.Dts.Story.2020.1080p.WEB-DL.H.264-GRP") == nil
    assert audio("Fake.Flac.Story.2020.1080p.WEB-DL.AAC2.0.H.264-GRP") == "AAC 2.0"
  end

  test "an audio tag ending the title zone is still a track" do
    assert audio("Fake.Story.EXTENDED.German.DTS.720p.BluRay.x264-GRP") == "DTS"
  end

  test "several tracks report the best tier" do
    assert audio("Fake Movie (2017) [BDRemux 1080p AVC ES DTS 5.1 - EN DTS-HD MA 7.1 Subs]") ==
             "DTS-HD MA 7.1"

    assert audio("Fake.Movie.2016.2160p.UHDRemux.HEVC.Dual.AC3.5.1-TrueHD.5.1.Sub") ==
             "TrueHD 5.1"

    assert audio("Fake Show S02 (2009)[BDRemux 1080p AVC Esp DD2.0,Ing DTS-HD5.1,Cat DD2.0 Subs]") ==
             "DTS-HD 5.1"

    assert audio("Fake Show S02 (2009)[BDRemux 1080p AVC Esp.DD2.0,Ing.DD2.0,Subs]") == "AC3 2.0"
  end

  test "DTS shorthands" do
    assert audio("Fake.Movie.2013.1080p.BluRay.REMUX.AVC.DTS-MA.5.1-GRP") == "DTS-HD MA 5.1"
    assert audio("Fake.Movie.2013.1080p.BluRay.REMUX.AVC.DTS-HD.MA5.1-GRP") == "DTS-HD MA 5.1"
    assert audio("Fake.Movie.2008.1080p.BluRay.AVC.DTS-HR.MA.5.1-GRP") == "DTS-HD MA 5.1"
    assert audio("Fake.Show.S20E13.1080p.BluRay.DTS-ES.5.1.x264-GRP") == "DTS 5.1"
    assert audio("Fake.Show.2009.S01.1080p.BluRay.DTS5.1.x264-GRP") == "DTS 5.1"
    assert audio("Fake Show - S01E01 - Ep [HEVC 4k DTSHD-MA-6ch]") == "DTS-HD MA"
  end

  test "audio dash-joined to other metadata" do
    assert audio("[Grp] Fake Show - 01 [BD][720p-AAC][0601BED4]") == "AAC"
    assert audio("Fake.Show.S03E01.DUAL.XviD.Bluray.AC3-REPACK.-GRP") == "AC3"
    assert audio("Fake.Movie.1994.German.AC3D.DL.720p.BluRay.x264-GRP") == "AC3"
    assert audio("Fake.Movie.2024.German.EAC3D.DL.2160p.WEB.HEVC-GRP") == "DD+"
  end
end
