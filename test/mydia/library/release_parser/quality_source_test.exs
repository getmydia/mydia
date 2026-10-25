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

    # cam-tier letters inside ordinary words ("ghoSTS", "waTChmaker",
    # "sCAMpers") once read as Telesync, Telecine and CAM
    assert source("Fake.Ghosts.of.Lights.2020.1080p.x264-GRP") == nil
    assert source("The.Watchmaker.Scampers.2020.2160p.HDR.x265-GRP") == nil

    parsed = ReleaseParser.parse("The.Screener.2020.1080p.x264-GRP")
    assert parsed.quality.source == nil
    assert parsed.title == "The Screener"
  end

  describe "cam-tier words in an episode title" do
    alias Mydia.Library.ReleaseParser.EpisodeTitle

    test "a short form counts only in capitals" do
      title = "Fake.Show.S02E03.Cam.and.Mitch.1080p.x264-GRP"
      parsed = ReleaseParser.parse(title)
      assert parsed.quality.source == nil
      assert {parsed.title, parsed.season, parsed.episodes} == {"Fake Show", 2, [3]}
      assert EpisodeTitle.extract(title) == "Cam and Mitch"

      title = "Fake.Show.S01E04.Tc.Talk.720p.x264-GRP"
      assert source(title) == nil
      assert EpisodeTitle.extract(title) == "Tc Talk"
    end

    test "a long form beside another title word is a title word" do
      title = "Fake.Show.S01E04.The.Screener.720p.x264-GRP"
      parsed = ReleaseParser.parse(title)
      assert parsed.quality.source == nil
      assert {parsed.title, parsed.season, parsed.episodes} == {"Fake Show", 1, [4]}
      assert EpisodeTitle.extract(title) == "The Screener"

      assert source("Fake.Show.S01E04.Telecine.Night.720p.x264-GRP") == nil
      assert source("Fake.Show.S01E04.Workprint.Blues.720p.x264-GRP") == nil
    end

    test "a tag after the marker still counts" do
      assert source("Fake.Show.S01E04.Screener.720p.x264-GRP") == "Screener"
      assert source("Fake.Show.S01E04.SCREENER.Some.Title.x264-GRP") == "Screener"
      assert source("Fake.Show.S01E04.720p.TS.x264-GRP") == "Telesync"
    end

    test "capitalised short forms and long forms still count in a movie" do
      assert source("Fake.Movie.2020.CAM.x264-GRP") == "CAM"
      assert source("Fake.Movie.2020.TS.x264-GRP") == "Telesync"
      assert source("Fake.Movie.2020.SCREENER.x264-GRP") == "Screener"
      assert source("Fake.Movie.2020.Screener.x264-GRP") == "Screener"
      assert source("Fake.Movie.2020.cam.x264-GRP") == nil
    end
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

  describe "Mydia's own renamer tag with a revision flag" do
    alias Mydia.Library.FileNamer

    defp renamer_quality(source, resolution, proper, repack) do
      %{
        source: source,
        resolution: resolution,
        codec: "x264",
        audio: nil,
        hdr_format: nil,
        dolby_vision: false,
        proper: proper,
        repack: repack
      }
    end

    test "a movie" do
      for {source, resolution, proper, repack} <- [
            {"BluRay", "1080p", true, false},
            {"HDTV", "720p", false, true},
            {"BluRay", "2160p", true, true},
            {"WEB-DL", "1080p", false, true}
          ] do
        name =
          FileNamer.generate_movie_filename(
            %{title: "Fake Movie", year: 2020},
            renamer_quality(source, resolution, proper, repack),
            "Fake.Movie.2020.x264-GRP.mkv"
          )

        parsed = ReleaseParser.parse(name)
        assert parsed.quality.source == source, name
        assert parsed.quality.resolution == resolution, name
        assert {parsed.quality.proper, parsed.quality.repack} == {proper, repack}, name
        assert {parsed.title, parsed.year} == {"Fake Movie", 2020}, name
      end
    end

    test "an episode" do
      name =
        FileNamer.generate_episode_filename(
          %{title: "Fake Show", year: 2019},
          %{season_number: 1, episode_number: 2, title: "Some Episode"},
          renamer_quality("HDTV", "720p", true, false),
          "Fake.Show.S01E02.x264-GRP.mkv"
        )

      assert name =~ "[HDTV-720p-Proper]"
      parsed = ReleaseParser.parse(name)
      assert {parsed.quality.source, parsed.quality.resolution} == {"HDTV", "720p"}
      assert {parsed.quality.proper, parsed.quality.repack} == {true, false}
      assert {parsed.title, parsed.season, parsed.episodes} == {"Fake Show", 1, [2]}
    end
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

  describe "WEB-DL variants" do
    test "a number before it, so the title zone runs through it" do
      parsed = ReleaseParser.parse("Fake.Show.1.WEB-DL.720p.Complete.Latino.GRP")
      assert parsed.quality.source == "WEB-DL"
      assert parsed.title == "Fake Show 1"
    end

    test "dash-joined to the episode marker and the resolution" do
      parsed = ReleaseParser.parse("Fake Show S1E1-WEB-DL-1080p-NZBgeek")
      assert parsed.quality.source == "WEB-DL"
      assert {parsed.season, parsed.episodes} == {1, [1]}
      assert source("Fake Show S1-E1-WEB-DL-1080p-NZBgeek") == "WEB-DL"
      assert source("fake.show.s03e16.h264.720p-web-handbrake.mkv") == "WEB-DL"
    end

    test "rip and mux suffixes, which QualityParser also reads as WEB-DL" do
      assert source("Fake.Movie.2020.WEB-DLRip.AVC.AC3.EN-GRP") == "WEB-DL"
      assert source("Fake Show (Season 1) (2022) WEB-DLRip-AVC Eng") == "WEB-DL"
      assert source("Fake.Show.6x10.Some.Episode.ITA.ENG.720p.WEB-DLMux.H.264-GRP") == "WEB-DL"
      assert source("Fake.Movie.[2021].1080p.WEB-HDRip.Dual.Audio.x264.AAC-GRP") == "WEB-DL"
    end

    test "bracketed, in the title zone of an anchorless anime name" do
      assert source("[Grp] Fake Show - 07 [Site][WEB-DL][1080p][AVC AAC][MP4]") == "WEB-DL"
      assert source("[Grp] 偽の番組 Fake Show - 07 [Site][WEB-DL][1080p][AVC AAC]") == "WEB-DL"
      assert source("[Grp] Fake Show: 30 [Web][MKV][h264][720p][AAC 2.0]") == "WEB-DL"

      assert source("[Grp] Fake Show - 01-17 (WEB 1080p x264 10-bit AAC) [Dual-Audio]") ==
               "WEB-DL"
    end

    test "bracketed with a group dash-joined to it" do
      assert source("Fake Show [2022] [S01E13] [PL] [720p] [WEB-DL-GRP] [x264] ") == "WEB-DL"
    end

    test "Web as a title word is still not a source" do
      parsed = ReleaseParser.parse("Fake.Web.Story.2020.1080p.BluRay.x264-GRP")
      assert parsed.quality.source == "BluRay"
      assert parsed.title == "Fake Web Story"

      assert source("[Grp] Fake Show (Spider Web) - 01 [1080p]") == nil
      assert source("[Grp] Fake Show [Web Story] - 01 [1080p]") == nil

      parsed = ReleaseParser.parse("Fake Show (Web) 2020 1080p BluRay x264-GRP")
      assert parsed.quality.source == "BluRay"
      assert parsed.title == "Fake Show (Web)"
    end

    test "a lone parenthesised scene abbreviation in the title stays a title word" do
      parsed = ReleaseParser.parse("Fake Movie (TS) 2020 1080p x264-GRP")
      assert parsed.quality.source == nil
      assert parsed.title == "Fake Movie (Ts)"
      assert source("Fake.Show.S01E01.Spider-Web.720p.HDTV.x264-GRP") == "HDTV"
    end
  end

  describe "WEBRip variants" do
    test "WEB Rip split by zero-width spaces" do
      parsed =
        ReleaseParser.parse(
          "Fake.Show.\u200BS07E11.\u200BWEB Rip.\u200BXviD.\u200BGrp-\u200BCZ.\u200BEN"
        )

      assert parsed.quality.source == "WEBRip"
      assert parsed.quality.codec == "XviD"
      assert {parsed.season, parsed.episodes} == {7, [11]}
      assert parsed.title == "Fake Show"
    end

    test "bracketed, in the title zone of an anchorless anime name" do
      assert source("[Grp-Raws][Fake Show 偽の番組][1008][Site][WEB-RIP][CHT][1080p][MKV]") ==
               "WEBRip"
    end
  end

  describe "other spellings" do
    test "a leading group tag ending in Remux is a fansub group, not a remux" do
      parsed = ReleaseParser.parse("[GRP-Remux].Fake.Show.X.21.720p.[76EA1C53].mkv")
      refute parsed.quality.source == "REMUX"
      assert parsed.title == "GRP-Remux Fake Show X 21"
    end

    test "a padded or multi-word leading group tag ending in Remux is not a remux" do
      for title <- [
            "[ GRP-Remux ] Fake Show - 21 [720p]",
            "[Some Subs-Remux] Fake Show - 21 [720p]"
          ] do
        refute ReleaseParser.parse(title).quality.source == "REMUX", title
      end
    end

    test "a codec in a non-leading bracket still splits" do
      parsed = ReleaseParser.parse("[Grp] Fake Show - 07 (1280x720 x264-AAC)")
      assert parsed.quality.codec == "x264"
    end

    test "a disc count before a DVD" do
      assert source("Fake.Movie.2000.2DVD5") == "DVD"
      assert source("Fake.Movie.2020.PAL.2xDVD9") == "DVD"
    end

    test "UHD downscaled to BD, and a disc size before Blu-ray" do
      parsed = ReleaseParser.parse("Fake.Movie.2012.German.DL.1080p.UHD2BD.x264-GRP")
      assert parsed.quality.source == "BluRay"
      assert parsed.quality.resolution == "1080p"

      parsed = ReleaseParser.parse("Fake.Movie.2008.Directors.Cut.UHD.BD66.Blu-ray")
      assert parsed.quality.source == "BluRay"
      assert parsed.release_group == nil
    end

    test "a group named Ray is still a group" do
      parsed = ReleaseParser.parse("Fake.Movie.2020.1080p.WEB-DL.x264-RAY")
      assert parsed.quality.source == "WEB-DL"
      assert parsed.release_group == "RAY"
    end
  end
end
