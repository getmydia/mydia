defmodule Mydia.Quality.SourcesTest do
  use ExUnit.Case, async: true

  alias Mydia.Quality.Sources

  # Titles that must NEVER be classified cam-tier. Covers three distinct
  # failure modes of the old unanchored patterns plus legitimate controls.
  @never_cam_tier [
    # substring matches inside ordinary words
    "Ghosts.of.Mars.2001.1080p.x264-GRP",
    "The.Watchmen.2009.2160p.HDR.x265",
    "Dutch.1991.1080p.x264",
    "Scream.VI.2023.1080p.x265-RARBG",
    "Cameron.Diaz.Doc.2020.1080p.x264",
    "Kitchen.Nightmares.S01E01.1080p.x264",
    "Lights.Out.2016.1080p.x264",
    # release-group suffixes in the hyphenated position
    "Some.Movie.2020.1080p.x264-WP",
    "Some.Movie.2020.1080p.x264-TS",
    "Some.Movie.2020.1080p.x264-TC",
    "Some.Movie.2020.2160p.HDR.DV.x265-SCR",
    # title-initial token
    "Ts.Madison.Show.2021.1080p.x264",
    # legitimate releases with explicit good sources
    "The.Matrix.1999.1080p.BluRay.x264",
    "Interstellar.2014.2160p.WEB-DL.x265",
    "Hitchcock.2012.1080p.WEBRip.x264",
    "Descriptions.2020.720p.HDTV.x264",
    # legitimate releases with no source token at all
    "WALL-E.2008.1080p.x264",
    "Wonka.2023.1080p.x264",
    "The.Big.Short.2015.1080p.x264",
    "Doctor.Who.2005.S01E01.1080p.x264"
  ]

  # Titles that must ALWAYS be classified cam-tier. The first three are real
  # releases grabbed by the production instance on 2026-08-04.
  @always_cam_tier [
    "The.Odyssey.2026.1080p.TELESYNC.HEVC.10bit.AAC2.0-SLH.mkv",
    "The Odyssey (2026) 1080p HQ HDTS - x264 - [Tel + Tam + Hin + Eng] - HQ Clean - 3.3GB.mkv",
    "Spider Man.Brand.New.Day.2026.1080p.TELESYNC.x264-DKS",
    "Movie.2026.TS.x264-GRP",
    "Movie.2026.HDCAM.x264",
    "Movie.2026.CAMRip.XviD",
    "Movie.2026.HDTS.x264",
    "Movie.2026.DVDScr.x264",
    "Movie.2026.WORKPRINT.x264",
    "Movie 2026 CAM x264",
    "Movie.2026.TC.x264-GRP",
    "Odyseja - The Odyssey 2026 [HGL HDR SDR] [1080p.TELESYNC.H264-AS76-FT] [ENG-Lektor PL AI] [Alusia]",
    # Real releases the production instance grabbed automatically on
    # 2026-08-12 and 2026-08-26. Both resolved to "DVD" because the bare `dvd`
    # pattern claimed the `dvd` inside `PreDVD` before the Telesync entry that
    # carries \bpredvd\b was ever tried, so no excluded_sources list rejected
    # them and each became its movie's only copy.
    "www.1TamilMV.top - Spider-Man Brand New Day (2026) HQ PreDVD - 1080p - x264 - [Tam + Tel + Hin + Eng] - HQ Clean - 5GB",
    "www.1TamilMV.ing - Insidious Out of the Further (2026) HQ PreDVD - 1080p - x264 - [Tam + Hin + Eng] - HQ Clean - AAC - 2GB",
    "Movie.2026.1080p.PreDVD.x264",
    "Movie.2026.1080p.PDVD.x264",
    "Movie 2026 HQ PreDVD 1080p x264"
  ]

  describe "cam_tier/0" do
    test "returns exactly the five cam-tier labels" do
      assert Sources.cam_tier() == ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]
    end
  end

  describe "cam_tier?/1" do
    test "true for every cam-tier label" do
      for label <- Sources.cam_tier() do
        assert Sources.cam_tier?(label)
      end
    end

    test "false for good sources and nil" do
      refute Sources.cam_tier?("BluRay")
      refute Sources.cam_tier?("WEB-DL")
      refute Sources.cam_tier?(nil)
    end
  end

  describe "detect/1 - must never be cam-tier" do
    for title <- @never_cam_tier do
      test "#{title}" do
        detected = Sources.detect(unquote(title))

        refute Sources.cam_tier?(detected),
               "expected #{unquote(title)} not to be cam-tier, got #{inspect(detected)}"
      end
    end
  end

  describe "detect/1 - must always be cam-tier" do
    for title <- @always_cam_tier do
      test "#{title}" do
        detected = Sources.detect(unquote(title))

        assert Sources.cam_tier?(detected),
               "expected #{unquote(title)} to be cam-tier, got #{inspect(detected)}"
      end
    end
  end

  describe "detect/1 - load-bearing table properties" do
    test "Screener is checked before DVD so DVDScr does not resolve DVD" do
      assert Sources.detect("Movie.2026.DVDScr.x264") == "Screener"
    end

    test "first-wins keeps an explicit good source ahead of a group suffix" do
      assert Sources.detect("Movie.2026.1080p.BluRay.x264-TS") == "BluRay"
    end

    test "PDVD and PreDVD resolve Telesync, not the bare DVD pattern" do
      assert Sources.detect("Movie.2026.1080p.PDVD.x264") == "Telesync"
      assert Sources.detect("Movie.2026.1080p.PreDVD.x264") == "Telesync"
      assert Sources.detect("Movie 2026 HQ PreDVD - 1080p - x264") == "Telesync"
    end

    test "the DVD lookbehinds do not cost a real DVD release its source" do
      assert Sources.detect("Movie.2026.DVD.x264") == "DVD"
      assert Sources.detect("Movie 2026 DVD x264") == "DVD"
      assert Sources.detect("Movie.2026.DVD5.x264") == "DVD"
      assert Sources.detect("Movie.2026.DVD9.x264") == "DVD"
      assert Sources.detect("Movie.2026.DVD-R.x264") == "DVD"
      assert Sources.detect("DVD.Movie.2026.x264") == "DVD"
    end

    test "good sources still resolve correctly" do
      assert Sources.detect("Movie.2026.1080p.BluRay.x264") == "BluRay"
      assert Sources.detect("Movie.2026.2160p.WEB-DL.x265") == "WEB-DL"
      assert Sources.detect("Movie.2026.1080p.WEBRip.x264") == "WEBRip"
      assert Sources.detect("Movie.2026.1080p.REMUX.x264") == "REMUX"
      assert Sources.detect("Show.S01E01.720p.HDTV.x264") == "HDTV"
      assert Sources.detect("Movie.2026.DVDRip.XviD") == "DVDRip"
    end

    test "returns nil when no source token is present" do
      assert Sources.detect("Movie.2026.1080p.x264") == nil
    end
  end

  describe "all/0" do
    test "includes every cam-tier label" do
      for label <- Sources.cam_tier() do
        assert label in Sources.all()
      end
    end

    test "includes the good sources" do
      assert "BluRay" in Sources.all()
      assert "WEB-DL" in Sources.all()
    end
  end
end
