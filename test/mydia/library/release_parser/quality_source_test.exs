defmodule Mydia.Library.ReleaseParser.QualitySourceTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser

  defp source(title), do: ReleaseParser.parse(title).quality.source

  test "cam-tier long forms" do
    assert source("Fake.Movie.2020.CAM.x264-GRP") == "CAM"
    assert source("Fake.Movie.2020.HDCAM.x264-GRP") == "CAM"
    assert source("Fake.Movie.2020.camrip.360p.x264-GRP") == "CAM"
    assert source("Fake.Movie.2020.HDTS.x264-GRP") == "Telesync"
    assert source("Fake.Movie.2020.Telesync.x264-GRP") == "Telesync"
    assert source("Fake.Movie.2020.PDVD.x264-GRP") == "Telesync"
    assert source("Fake.Movie.2020.HDTC.x264-GRP") == "Telecine"
    assert source("Fake.Movie.2020.DVDScr.x264-GRP") == "Screener"
    assert source("Fake.Movie.2020.Workprint.x264-GRP") == "Workprint"
  end

  test "delimited short forms count, group-position and leading ones do not" do
    assert source("Fake.Movie.2020.TS.x264-GRP") == "Telesync"
    assert source("Fake Movie 2020 [TC] x264-GRP") == "Telecine"
    refute source("Fake.Movie.2020.1080p.x264-TS") == "Telesync"
    refute source("Ts.Fake.Show.2021.1080p.x264-GRP") == "Telesync"
  end

  test "title words are not sources" do
    assert source("Some.Web.Show.2024.1080p.x264-GRP") == nil
    assert source("The.Cam.Story.2020.1080p.BluRay.x264-GRP") == "BluRay"

    parsed = ReleaseParser.parse("The.Screener.2020.1080p.x264-GRP")
    assert parsed.quality.source == nil
    assert parsed.title == "The Screener"
  end

  test "an explicit good source outranks a cam-tier token" do
    assert source("Fake.Movie.2020.HDTS.1080p.WEB-DL.x264-GRP") == "WEB-DL"
    assert source("Fake.Movie.2020.DVD.PDVD.x264-GRP") == "DVD"
  end

  test "TV sources" do
    assert source("Fake.Show.S01E01.PDTV.x264-GRP") == "PDTV"
    assert source("Fake.Show.S01E01.SDTV.x264-GRP") == "SDTV"
    assert source("Fake.Show.S01E01.HDTV.x264-GRP") == "HDTV"
  end

  test "REMUX beats BluRay" do
    assert source("Fake.Movie.2020.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-GRP") == "REMUX"
    assert source("Fake.Movie.2020.2160p.UHD.BluRay.Remux.HEVC-GRP") == "REMUX"
  end

  test "lowercase and hyphenated sources" do
    assert source("Fake.Movie.2020-1080p-bluray.mkv") == "BluRay"
    assert source("fake.movie.2020.1080p.webrip.x264-grp") == "WEBRip"
  end

  test "spellings glued into one word" do
    assert source("Fake.Movie.2020.1080p.WebDL.x264-GRP") == "WEB-DL"
    assert source("Fake.Show.S01E01.1080p.Blu-Ray.DTS.x264-GRP") == "BluRay"
    assert source("Fake Movie (2020) [BDRemux 1080p AVC]") == "REMUX"
    assert source("Fake Movie (2020) [UHDRemux 2160p HDR]") == "REMUX"
    assert source("Fake.Movie.2020.1080p.UHDBDRip.x265-GRP") == "BluRay"
    assert source("Fake.Movie.2020.720p.MBluRay.x264-GRP") == "BluRay"
    assert source("Fake.Movie.2020.PAL.DVDR-GRP") == "DVD"
    assert source("Fake.Movie.2020.DVD9.NTSC") == "DVD"
  end

  test "a source glued to its resolution, as Sonarr names files" do
    assert source("Fake Show - S01E01 - Pilot [HDTV-720p]") == "HDTV"
    assert source("Fake.Show.S01E01.Pilot.[WEBDL-1080p].mkv") == "WEB-DL"
    assert source("Fake Movie (2020) [Bluray-1080p].mkv") == "BluRay"
    assert source("Fake Movie (2020) [Remux-2160p HDR]") == "REMUX"
    assert source("Fake.Show.S01E01.Bluray1080p") == "BluRay"
    assert source("Fake Show - S01E01 - Pilot [WEB-DL-1080p]") == "WEB-DL"
  end

  test "a source dash-glued to its codec" do
    parsed = ReleaseParser.parse("Fake Show (Season 1) (2019) BDRip-AVC Eng")
    assert parsed.quality.source == "BluRay"
    assert parsed.quality.codec == "H.264"
    assert source("Fake Show (Season 1) (2018) WEBRip-AVC Eng") == "WEBRip"
  end

  test "a resolution glued to a non-source word does not split it" do
    parsed = ReleaseParser.parse("Fake Show Pilot-720p")
    assert parsed.quality.source == nil
    assert parsed.title == "Fake Show"
  end
end
