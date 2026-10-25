defmodule Mydia.Quality.SourcesTest do
  use ExUnit.Case, async: true

  alias Mydia.Quality.Sources

  # Titles that must NEVER be classified cam-tier. Covers three distinct
  # failure modes of the old unanchored patterns plus legitimate controls.
  @never_cam_tier [
    # substring matches inside ordinary words
    "Ghosts.of.Pellmar.2001.1080p.x264-GRP",
    "The.Watchmen.of.Orvale.2009.2160p.HDR.x265",
    "Dutch.Harbor.Blues.1991.1080p.x264",
    "Scream.Hollow.2023.1080p.x265-GRP",
    "Cameron.Vale.Doc.2020.1080p.x264",
    "Kitchen.Quarrels.S01E01.1080p.x264",
    "Lights.Below.Ferrin.2016.1080p.x264",
    # release-group suffixes in the hyphenated position
    "Some.Movie.2020.1080p.x264-WP",
    "Some.Movie.2020.1080p.x264-TS",
    "Some.Movie.2020.1080p.x264-TC",
    "Some.Movie.2020.2160p.HDR.DV.x265-SCR",
    # title-initial token
    "Ts.Marlow.Show.2021.1080p.x264",
    # legitimate releases with explicit good sources
    "The.Lattice.1999.1080p.BluRay.x264",
    "Starward.2014.2160p.WEB-DL.x265",
    "Hatchcroft.2012.1080p.WEBRip.x264",
    "Descriptions.2020.720p.HDTV.x264",
    # legitimate releases with no source token at all
    "KRANE-O.2008.1080p.x264",
    "Wonlo.2023.1080p.x264",
    "The.Tall.Shorts.2015.1080p.x264",
    "Doctor.Quill.2005.S01E01.1080p.x264"
  ]

  # Titles that must ALWAYS be classified cam-tier. The first three copy the
  # shape of releases the production instance grabbed on 2026-08-04, with the
  # titles replaced.
  @always_cam_tier [
    "The.Wayfarer.2026.1080p.TELESYNC.HEVC.10bit.AAC2.0-SLH.mkv",
    "The Wayfarer (2026) 1080p HQ HDTS - x264 - [Tel + Tam + Hin + Eng] - HQ Clean - 3.3GB.mkv",
    "Lantern Man.Bright.New.Hour.2026.1080p.TELESYNC.x264-DKS",
    "Movie.2026.TS.x264-GRP",
    "Movie.2026.HDCAM.x264",
    "Movie.2026.CAMRip.XviD",
    "Movie.2026.HDTS.x264",
    "Movie.2026.DVDScr.x264",
    "Movie.2026.WORKPRINT.x264",
    "Movie 2026 CAM x264",
    "Movie.2026.TC.x264-GRP",
    "Wedrowiec - The Wayfarer 2026 [HGL HDR SDR] [1080p.TELESYNC.H264-AS76-FT] [ENG-Lektor PL AI] [Alusia]",
    # The shape of releases the production instance grabbed automatically on
    # 2026-08-12 and 2026-08-26, titles replaced. Both once resolved to "DVD"
    # because a bare `dvd` pattern claimed the `dvd` inside `PreDVD`, so no
    # excluded_sources list rejected them and each became its movie's only
    # copy.
    "www.1TamilMV.top - Lantern-Man Bright New Hour (2026) HQ PreDVD - 1080p - x264 - [Tam + Tel + Hin + Eng] - HQ Clean - 5GB",
    "www.1TamilMV.ing - Hollowed Out of the Deeper (2026) HQ PreDVD - 1080p - x264 - [Tam + Hin + Eng] - HQ Clean - AAC - 2GB",
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

  describe "detect/1 - overlapping tokens" do
    test "DVDScr resolves Screener, not DVD" do
      assert Sources.detect("Movie.2026.DVDScr.x264") == "Screener"
    end

    test "an explicit good source wins over a group suffix" do
      assert Sources.detect("Movie.2026.1080p.BluRay.x264-TS") == "BluRay"
    end

    test "PDVD and PreDVD resolve Telesync, not DVD" do
      assert Sources.detect("Movie.2026.1080p.PDVD.x264") == "Telesync"
      assert Sources.detect("Movie.2026.1080p.PreDVD.x264") == "Telesync"
      assert Sources.detect("Movie 2026 HQ PreDVD - 1080p - x264") == "Telesync"
    end

    test "a real DVD release keeps its source" do
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

    test "a bare WEB token resolves WEB-DL" do
      assert Sources.detect("Movie.2026.1080p.WEB.H264-GRP") == "WEB-DL"
      assert Sources.detect("Show 2026 S01E01 1080p WEB h264-GRP") == "WEB-DL"
      assert Sources.detect("Show.2026.S01E01.1080p.WEB-GRP") == "WEB-DL"
      assert Sources.detect("Movie.2026.2160p.4K.WEB.x265.10bit.AAC5.1-[GRP].mkv") == "WEB-DL"
    end

    test "a WEB title word never outranks a cam-tier token" do
      assert Sources.detect("Copper.Web.2026.1080p.TELESYNC.x264") == "Telesync"
      assert Sources.detect("Copper.Web.2026.CAM.x264") == "CAM"
    end

    test "WEB inside a longer word is not a source" do
      assert Sources.detect("Webster.Lane.2026.1080p.x264") == nil
      assert Sources.detect("Cobweb.2026.1080p.x264") == nil
    end

    test "returns nil when no source token is present" do
      assert Sources.detect("Movie.2026.1080p.x264") == nil
    end

    test "agrees with QualityParser on a title carrying a slash" do
      title = "Movie 2026 1080p / BluRay / x264"

      assert Sources.detect(title) == "BluRay"
      assert Sources.detect(title) == Mydia.Indexers.QualityParser.parse(title).source
    end
  end

  describe "detect/1 - on-disk relative paths" do
    test "detects cam-tier releases already sitting in the library" do
      # The shape of the file the production instance imported on 2026-08-04.
      path =
        "Starfall Requiem (2026)/Starfall Requiem (2026) 1080p HQ HDTS - x264 - [Tel + Tam + Hin + Eng] - HQ Clean - 3.3GB.mkv"

      assert Sources.cam_tier?(Sources.detect(path))
    end

    test "still detects good sources" do
      assert Sources.detect("Neon Cascade (1999)/Neon.Cascade.1999.1080p.BluRay.x264.mkv") ==
               "BluRay"

      assert Sources.detect("Voyagers Reach (2014)/Voyagers.Reach.2014.2160p.WEB-DL.x265.mkv") ==
               "WEB-DL"
    end

    test "returns nil when the path carries no source token" do
      assert Sources.detect("Sugarcane Dreams (2023)/Sugarcane.Dreams.2023.1080p.mkv") ==
               nil
    end
  end

  describe "all/0" do
    test "lists the source vocabulary in display order" do
      # The manual-search Source filter lists its options in this order.
      assert Sources.all() == [
               "REMUX",
               "BluRay",
               "WEB-DL",
               "WEBRip",
               "HDTV",
               "SDTV",
               "DVDRip",
               "Screener",
               "DVD",
               "Telecine",
               "Telesync",
               "CAM",
               "Workprint",
               "PDTV"
             ]
    end

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
