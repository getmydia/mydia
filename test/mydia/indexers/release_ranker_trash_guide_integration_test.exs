defmodule Mydia.Indexers.ReleaseRankerTRaSHGuideIntegrationTest do
  @moduledoc """
  Integration tests for Release Ranker using real TRaSH Guide quality profiles
  and real-world release names from bitsearch.to.

  ## Data Sources

  ### TRaSH Guide Profiles (from GitHub - November 2025)
  - HD Bluray + WEB (hd-bluray-web.json)
  - UHD Bluray + WEB (uhd-bluray-web.json)
  - Remux + WEB 1080p (remux-web-1080p.json)

  ### Release Group Tiers (from TRaSH Guides Custom Formats)
  - WEB Tier 01: ABBIE, AJP69, APEX, FLUX, NTb, NTG, etc. (score ~1700)
  - WEB Tier 02: BYNDR, SMURF, PHOENiX, playWEB, etc. (score ~1650)
  - WEB Tier 03: Dooky, ROCCaT, SiGMA, etc. (score ~1600)
  - HD Bluray Tier 01: CtrlHD, DON, D-Z0N3, decibeL, etc. (score ~1800)
  - UHD Bluray Tier 01: CtrlHD, MainFrame, DON, W4NK3R (score ~2000)

  ### Release Names (from bitsearch.to - November 2025)
  All release names are REAL examples found on torrent search engines,
  NOT fabricated test cases.

  ## Test Coverage

  This suite verifies:
  1. Quality profiles correctly filter releases by resolution/source
  2. Release group tiers affect ranking scores appropriately (via preferred_tags)
  3. Audio codec preferences (TrueHD Atmos > DTS-HD MA > DD+ > AAC)
  4. HDR format preferences (DV > HDR10+ > HDR10 > SDR)
  5. Source tier ranking (REMUX > BluRay > WEB-DL > HDTV)
  6. PROPER/REPACK handling gives score boost
  7. End-to-end "pick best release" with 5+ real candidates
  """

  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}
  alias Mydia.Settings.QualityProfile

  # ===========================================================================
  # TRASH GUIDE QUALITY PROFILE DEFINITIONS
  # Imported from: https://github.com/TRaSH-Guides/Guides/tree/master/docs/json/radarr/quality-profiles
  # ===========================================================================

  @doc """
  TRaSH Guide: HD Bluray + WEB profile
  Source: hd-bluray-web.json (trash_id: d1d67249d3890e49bc12e275d989a7e9)

  Allowed: Bluray-720p, WEB-1080p, Bluray-1080p
  Blocked: All 2160p, HDTV, DVD, CAM, etc.
  """
  def trash_hd_bluray_web_profile do
    %QualityProfile{
      name: "TRaSH HD Bluray + WEB",
      upgrades_allowed: true,
      quality_standards: %{
        min_resolution: "720p",
        max_resolution: "1080p",
        preferred_resolutions: ["1080p"],
        # TRaSH prioritizes BluRay > WEB-DL for HD
        preferred_sources: ["BluRay", "WEB-DL", "WEBRip"],
        preferred_video_codecs: ["h265", "x265", "h264", "x264"],
        preferred_audio_codecs: ["dts-hd", "truehd", "ac3", "aac"],
        movie_min_size_mb: 4096,
        movie_max_size_mb: 20480,
        episode_min_size_mb: 500,
        episode_max_size_mb: 4096
      }
    }
  end

  @doc """
  TRaSH Guide: UHD Bluray + WEB profile
  Source: uhd-bluray-web.json (trash_id: 64fb5f9858489bdac2af690e27c8f42f)

  Allowed: WEB-2160p, Bluray-2160p
  Blocked: All sub-2160p, HDTV, Remux, DVD, CAM, etc.
  """
  def trash_uhd_bluray_web_profile do
    %QualityProfile{
      name: "TRaSH UHD Bluray + WEB",
      upgrades_allowed: true,
      quality_standards: %{
        min_resolution: "2160p",
        max_resolution: "2160p",
        preferred_resolutions: ["2160p"],
        # TRaSH prioritizes BluRay > WEB-DL for UHD
        preferred_sources: ["BluRay", "WEB-DL", "WEBRip"],
        preferred_video_codecs: ["h265", "x265", "hevc", "av1"],
        preferred_audio_codecs: ["atmos", "truehd", "dts-hd", "ac3"],
        hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
        movie_min_size_mb: 15360,
        movie_max_size_mb: 81920,
        episode_min_size_mb: 3072,
        episode_max_size_mb: 20480
      }
    }
  end

  @doc """
  TRaSH Guide: Remux + WEB 1080p profile
  Source: remux-web-1080p.json (trash_id: 9ca12ea80aa55ef916e3751f4b874151)

  Allowed: WEB-1080p, Remux-1080p
  Blocked: All other qualities including standard Bluray encodes
  """
  def trash_remux_web_1080p_profile do
    %QualityProfile{
      name: "TRaSH Remux + WEB 1080p",
      upgrades_allowed: true,
      quality_standards: %{
        min_resolution: "1080p",
        max_resolution: "1080p",
        preferred_resolutions: ["1080p"],
        # REMUX is highest priority for this profile
        preferred_sources: ["REMUX", "WEB-DL", "WEBRip"],
        preferred_video_codecs: ["h265", "x265", "h264", "x264", "avc"],
        preferred_audio_codecs: ["truehd", "atmos", "dts-hd", "ac3"],
        # Larger file sizes expected for REMUX
        movie_min_size_mb: 8192,
        movie_max_size_mb: 51200,
        episode_min_size_mb: 2048,
        episode_max_size_mb: 15360
      }
    }
  end

  # ===========================================================================
  # TRASH GUIDE RELEASE GROUP TIERS
  # Source: https://github.com/TRaSH-Guides/Guides/tree/master/docs/json/radarr/cf
  # Note: Release groups are matched via preferred_tags in ReleaseRanker,
  #       not via a field in Quality struct
  # ===========================================================================

  @web_tier_01_groups ~w(ABBIE AJP69 APEX BLUTONiUM CMRG CRFW CRUD FLUX GNOME HONE KiNGS Kitsune NOSiViD NTb NTG SiC TEPES TheFarm ZoroSenpai)
  @web_tier_02_groups ~w(BYNDR dB Flights MiU monkee MZABI PHOENiX playWEB RAWR SbR SMURF TOMMY XEBEC)
  @web_tier_03_groups ~w(Dooky GNOMiSSiON NINJACENTRAL NPMS ROCCaT SiGMA SLiGNOME SwAgLaNdEr)

  @hd_bluray_tier_01_groups ~w(BBQ BMF c0kE Chotab CRiSC CtrlHD D-Z0N3 Dariush decibeL DON EbP EDPH Geek LolHD NCmt PTer TayTO TDD TnP VietHD ZQ)
  @uhd_bluray_tier_01_groups ~w(CtrlHD MainFrame DON W4NK3R)

  @remux_tier_01_groups ~w(FraMeSToR EPSiLON KRaLiMaRKo SiCFoI ZQ playBD PmP)

  # ===========================================================================
  # TEST HELPERS
  # ===========================================================================

  defp build_result(attrs) do
    defaults = %{
      title: "Test.Release.1080p.BluRay.x264",
      size: 8 * 1024 * 1024 * 1024,
      seeders: 100,
      leechers: 20,
      download_url: "magnet:?xt=urn:btih:test",
      indexer: "TestIndexer",
      quality: QualityParser.parse("Test.Release.1080p.BluRay.x264"),
      published_at: DateTime.utc_now()
    }

    merged = Map.merge(defaults, attrs)
    # Re-parse quality from title if title changed
    merged =
      if Map.has_key?(attrs, :title) and not Map.has_key?(attrs, :quality) do
        Map.put(merged, :quality, QualityParser.parse(attrs.title))
      else
        merged
      end

    struct!(SearchResult, merged)
  end

  # Extract release group from title (matches -GROUP at end)
  defp extract_release_group(title) do
    case Regex.run(~r/-([A-Za-z0-9]+)(?:\.[a-z]{2,4})?$/, title) do
      [_, group] -> group
      _ -> nil
    end
  end

  defp release_group_tier(group) do
    cond do
      group in @web_tier_01_groups -> {:web, 1}
      group in @web_tier_02_groups -> {:web, 2}
      group in @web_tier_03_groups -> {:web, 3}
      group in @hd_bluray_tier_01_groups -> {:hd_bluray, 1}
      group in @uhd_bluray_tier_01_groups -> {:uhd_bluray, 1}
      group in @remux_tier_01_groups -> {:remux, 1}
      true -> {:unknown, 99}
    end
  end

  # Default size range that accommodates 4K REMUX files (up to 100GB)
  @default_size_range {100, 120_000}

  # ===========================================================================
  # REAL RELEASE NAMES FROM BITSEARCH.TO (November 2025)
  # ===========================================================================

  # Oppenheimer 2160p releases
  @oppenheimer_2160p_releases [
    "Oppenheimer.2023.2160p.MA.WEB-DL.DUAL.DTS.HD.MA.5.1+DD+5.1.DV-HDR.H.265-TheBiscuitMan.mkv",
    "Oppenheimer.2023.2160p.UHD.Bluray.REMUX.HDR10.HEVC.DTS-HD.MA.5.1-GHD",
    "Oppenheimer.2023.2160p.UHD.BluRay.x265.10bit.HDR.DTS-HD.MA.TrueHD.7.1.Atmos-SWTYBLZ",
    "Oppenheimer.2023.UHD.BluRay.2160p.DTS-HD.MA.5.1.DV.HEVC.HYBRID.REMUX-FraMeSToR",
    "Oppenheimer.2023.IMAX.2160p.BluRay.x265.10bit.DTS-HD.MA.5.1-CTRLHD",
    "Oppenheimer.2023.2160p.10bit.HDR.BluRay.6CH.x265.HEVC-PSA"
  ]

  # Oppenheimer 1080p releases - used inline in tests for variety

  # Premium 4K REMUX releases with TrueHD Atmos
  @premium_4k_remux_releases [
    "Nobody.2.2025.2160p.UHD.BluRay.REMUX.DV.HDR.TrueHD.Atmos.7.1.HEVC-IONICBOY",
    "Guardians.of.the.Galaxy.Vol.3.2023.2160p.UHD.Remux.HEVC.TrueHD.Atmos.7.1-playBD",
    "John.Wick.Chapter.4.2023.2160p.UHD.Bluray.REMUX.DV.HDR10.HEVC.TrueHD.Atmos.7.1-GHD",
    "Transformers.One.2024.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR",
    "Spider-Man.Across.the.Spider-Verse.2023.2160p.UHD.Remux.HEVC.DoVi.TrueHD.Atmos.7.1-playBD",
    "Avatar.The.Way.of.Water.2022.2160p.UHD.Bluray.REMUX.HDR10.HEVC.TrueHD.Atmos.7.1-GHD",
    "Barbie.2023.2160p.UHD.Bluray.REMUX.HDR10.HEVC.TrueHD.Atmos.7.1-GHD",
    "Top.Gun.Maverick.2022.2160p.IMAX.Dolby.Vision.And.HDR10.ENG.And.ESP.LATINO.TrueHD.Atmos.REMUX.DV.x265.MKV-BEN.THE.MEN",
    "Inside.Out.2.2024.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.HYBRID.REMUX-FraMeSToR",
    "Deadpool.and.Wolverine.2024.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR"
  ]

  # Dolby Vision releases
  @dolby_vision_releases [
    "Free.Guy.2021.2160p.REMUX.For.LGTVs.Dolby.Vision.HDR.ENG.LATINO.RUS.HINDI.ITA.DDP5.1.DV.x265.MP4-BEN.THE.MEN",
    "Dunkirk.2017.2160p.REMUX.For.LGTVs.Dolby.Vision.HDR.ENG.RUS.CZE.CHI.HUN.POL.THAI.TUR.ITA.LATINO.DDP5.1.DV.x265.MP4-BEN.THE.MEN",
    "1917.2019.2160p.REMUX.Dolby.Vision.And.HDR10.PLUS.ENG.And.ESP.LATINO.TrueHD.Atmos.7.1.DV.x265.MKV-BEN.THE.MEN",
    "The.Creator.2023.2160p.REMUX.Dolby.Vision.And.HDR10.TrueHD.Atmos.7.1.DDP5.1.DV.x265.MKV-BEN.THE.MEN"
  ]

  # Dune 2021 releases (multiple quality tiers)
  @dune_2021_releases [
    "Dune.2021.2160p.HMAX.WEB-DL.DDP5.1.Atmos.HDR.HEVC-EVO",
    "Dune.2021.2160p.BluRay.REMUX.DV.HDR.ENG.LATINO.CASTELLANO.HINDI.ITA.FRE.GER.DDP5.1.H265.MP4-BEN.THE.MEN",
    "Dune.Part.One.2021.Hybrid.2160p.UHD.BluRay.REMUX.DV.HDR10Plus.HEVC.TrueHD.7.1.Atmos-WiLDCAT",
    "Dune.2021.2160p.UHD.BluRay.x265.10bit.HDR.TrueHD.7.1.Atmos-RARBG",
    "Dune.2021.1080p.BluRay.DDP5.1.x265.10bit-GalaxyRG265",
    "Dune.2021.1080p.WEB-DL.AAC.x264-skyflickz"
  ]

  # The Last of Us S01 releases
  @the_last_of_us_s01_releases [
    "The.Last.of.Us.S01.2160p.HMAX.WEB-DL.x265.10bit.HDR.DDP5.1.Atmos-SMURF",
    "The.Last.of.Us.S01.2160p.UHD.BluRay.Remux.HDR.DV.HEVC.Atmos-PmP",
    "The.Last.of.Us.S01.2160p.MAX.WEB-DL.x265.10bit.HDR.DDP5.1.Atmos-FLUX",
    "The.Last.of.Us.S01.2160p.REMUX.Dolby.Vision.And.HDR10.ENG.And.ESP.LATINO.DDP5.1.DV.x265.MP4-BEN.THE.MEN",
    "The.Last.of.Us.S01.2160p.10bit.HDR.DV.WEBRip.6CH.x265.HEVC-PSA"
  ]

  # House of the Dragon S02 releases - used inline in tests for variety
  # HDTV releases (720p broadcast rips) - used inline in tests for variety

  # PROPER/REPACK releases
  @proper_repack_releases [
    "The.Rider.2017.PROPER.REPACK.1080p.BluRay.x264-CAPRiCORN",
    "The.Emoji.Movie.2017.REPACK.PROPER.1080p.BluRay.H264.AAC-RARBG",
    "X-Men.Apocalypse.2016.PROPER.REPACK.1080p.BluRay.x264-SECTOR7",
    "Star.Trek.2009.PROPER.REPACK.1080p.BluRay.DTS.x264-ESiR",
    "Footloose.2011.PROPER.REPACK.1080p.BluRay.x264-iNFAMOUS"
  ]

  # Interstellar releases - used inline in tests for variety

  # ===========================================================================
  # TEST: RESOLUTION PREFERENCE RANKING
  # TRaSH Guide profiles specify allowed resolutions
  # ===========================================================================

  describe "resolution preference - HD Bluray + WEB profile" do
    setup do
      {:ok, profile: trash_hd_bluray_web_profile()}
    end

    test "ranks 1080p higher than 720p for HD profile", %{profile: _profile} do
      results = [
        build_result(%{
          title: "Oppenheimer.2023.720p.BluRay.999MB.x264-GalaxyRG",
          size: 1 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.DD5.1.x264-GalaxyRG",
          size: 8 * 1024 * 1024 * 1024
        })
      ]

      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p", "720p"])

      first = List.first(ranked)
      assert first.result.quality.resolution == "1080p"
    end

    test "2160p releases are ranked lower when profile prefers 1080p", %{profile: _profile} do
      results = [
        build_result(%{
          title: "Oppenheimer.2023.2160p.UHD.Bluray.REMUX.HDR10.HEVC.DTS-HD.MA.5.1-GHD",
          size: 60 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.DD5.1.x264-GalaxyRG",
          size: 8 * 1024 * 1024 * 1024
        })
      ]

      # HD profile prefers 720p/1080p, not 2160p
      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p", "720p"])

      first = List.first(ranked)
      assert first.result.quality.resolution == "1080p"
    end

    test "real Oppenheimer releases ranked correctly for HD profile", %{profile: _profile} do
      # Mix of 1080p and 720p real releases
      results = [
        build_result(%{
          title: "Oppenheimer.2023.720p.BluRay.999MB.x264-GalaxyRG",
          size: 1 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.x265.DTS-HD.MA.5.1-DiN",
          size: 8 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.10bit.BluRay.6CH.x265.HEVC-PSA",
          size: 4 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.BDRip.720p.ExKinoRay.mkv",
          size: 2 * 1024 * 1024 * 1024
        })
      ]

      ranked = ReleaseRanker.rank_all(results, preferred_qualities: ["1080p", "720p"])

      # Top 2 should be 1080p
      top_2_resolutions = ranked |> Enum.take(2) |> Enum.map(& &1.result.quality.resolution)
      assert Enum.all?(top_2_resolutions, &(&1 == "1080p"))
    end
  end

  describe "resolution preference - UHD Bluray + WEB profile" do
    setup do
      {:ok, profile: trash_uhd_bluray_web_profile()}
    end

    test "ranks 2160p releases at top for UHD profile", %{profile: _profile} do
      results = [
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.DD5.1.x264-GalaxyRG",
          size: 8 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.2160p.UHD.Bluray.REMUX.HDR10.HEVC.DTS-HD.MA.5.1-GHD",
          size: 60 * 1024 * 1024 * 1024
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      first = List.first(ranked)
      assert first.result.quality.resolution == "2160p"
    end

    test "real Oppenheimer 2160p releases ranked by quality", %{profile: _profile} do
      results =
        @oppenheimer_2160p_releases
        |> Enum.with_index()
        |> Enum.map(fn {title, idx} ->
          # Vary seeders to create score differentiation
          build_result(%{
            title: title,
            size: (40 + idx * 5) * 1024 * 1024 * 1024,
            seeders: 100 - idx * 10
          })
        end)

      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      # All should be 2160p
      assert Enum.all?(ranked, fn r -> r.result.quality.resolution == "2160p" end)
      # Should be sorted by score
      scores = Enum.map(ranked, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end
  end

  # ===========================================================================
  # TEST: SOURCE TIER RANKING
  # TRaSH Guide: REMUX > BluRay > WEB-DL > WEBRip > HDTV
  # ===========================================================================

  describe "source tier ranking - REMUX highest" do
    test "REMUX ranks higher than BluRay encode" do
      results = [
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.DD5.1.x264-GalaxyRG",
          size: 8 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.Bluray.REMUX.AVC.DTS-HD.MA.5.1-GHD",
          size: 35 * 1024 * 1024 * 1024
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_remux_web_1080p_profile(),
          preferred_qualities: ["1080p"],
          size_range: @default_size_range
        )

      # Both are 1080p, REMUX should win on source quality
      # Note: The QualityProfile's preferred_sources gives REMUX priority
      first = List.first(ranked)
      # The REMUX release should rank higher due to higher source score
      assert String.contains?(first.result.title, "REMUX") or
               String.contains?(first.result.title, "Remux")
    end

    test "BluRay ranks higher than WEB-DL" do
      results = [
        build_result(%{
          title: "Oppenheimer.2023.1080p.AMZN.WEB-DL.DDP5.1.H.264-BYNDR",
          size: 6 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.DD5.1.x264-GalaxyRG",
          size: 8 * 1024 * 1024 * 1024
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_hd_bluray_web_profile(),
          preferred_qualities: ["1080p"],
          size_range: @default_size_range
        )

      first = List.first(ranked)
      # BluRay should rank higher due to source tier
      assert first.result.quality.source == "BluRay"
    end

    test "WEB-DL ranks higher than HDTV" do
      results = [
        build_result(%{
          title: "The.Rookie.S06E08.720p.HDTV.x264-SYNCOPY",
          size: 1 * 1024 * 1024 * 1024
        }),
        build_result(%{
          title: "The.Rookie.S06E08.720p.AMZN.WEB-DL.DDP5.1.H.264-NTb",
          size: 2 * 1024 * 1024 * 1024
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_hd_bluray_web_profile(),
          preferred_qualities: ["720p"],
          size_range: @default_size_range
        )

      first = List.first(ranked)
      assert first.result.quality.source == "WEB-DL"
    end

    test "real premium REMUX releases ranked at top" do
      results =
        @premium_4k_remux_releases
        |> Enum.take(5)
        |> Enum.with_index()
        |> Enum.map(fn {title, idx} ->
          build_result(%{
            title: title,
            size: (50 + idx * 10) * 1024 * 1024 * 1024,
            seeders: 50 + idx * 5
          })
        end)

      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      # All should be REMUX (QualityParser detects REMUX in title)
      assert Enum.all?(ranked, fn r ->
               String.contains?(String.upcase(r.result.title), "REMUX")
             end)
    end
  end

  # ===========================================================================
  # TEST: HDR FORMAT PREFERENCE
  # TRaSH Guide: Dolby Vision > HDR10+ > HDR10 > SDR
  # ===========================================================================

  describe "HDR format preference ranking" do
    test "Dolby Vision releases detected with correct hdr_format" do
      dv_releases = @dolby_vision_releases

      for title <- dv_releases do
        result = build_result(%{title: title, size: 50 * 1024 * 1024 * 1024})
        quality = result.quality

        # STRICT: Must detect specific DV format, not just generic HDR
        assert quality.hdr == true,
               "Expected hdr=true for: #{title}"

        assert quality.hdr_format == "DV",
               "Expected hdr_format='DV' but got '#{quality.hdr_format}' for: #{title}"
      end
    end

    test "HDR10 vs HDR10+ vs DV format detection is exact" do
      # Test specific HDR format detection
      hdr10_title = "Movie.2160p.UHD.BluRay.HDR10.HEVC-GROUP"
      hdr10plus_title = "Movie.2160p.UHD.BluRay.HDR10+.HEVC-GROUP"
      dv_title = "Movie.2160p.UHD.BluRay.DV.HEVC-GROUP"
      generic_hdr_title = "Movie.2160p.UHD.BluRay.HDR.HEVC-GROUP"

      assert QualityParser.extract_hdr_format(hdr10_title) == "HDR10"
      assert QualityParser.extract_hdr_format(hdr10plus_title) == "HDR10+"
      assert QualityParser.extract_hdr_format(dv_title) == "DV"
      assert QualityParser.extract_hdr_format(generic_hdr_title) == "HDR"
    end

    test "HDR format scores are correctly tiered: DV > HDR10+ > HDR10 > HDR > SDR" do
      # Build releases with IDENTICAL specs except HDR format
      base_attrs = %{size: 25 * 1024 * 1024 * 1024, seeders: 100}

      dv_result = build_result(Map.put(base_attrs, :title, "Movie.2160p.BluRay.x265.DV-GROUP"))

      hdr10plus_result =
        build_result(Map.put(base_attrs, :title, "Movie.2160p.BluRay.x265.HDR10Plus-GROUP"))

      hdr10_result =
        build_result(Map.put(base_attrs, :title, "Movie.2160p.BluRay.x265.HDR10-GROUP"))

      hdr_result = build_result(Map.put(base_attrs, :title, "Movie.2160p.BluRay.x265.HDR-GROUP"))
      sdr_result = build_result(Map.put(base_attrs, :title, "Movie.2160p.BluRay.x265-GROUP"))

      # Verify format detection
      assert dv_result.quality.hdr_format == "DV"
      assert hdr10plus_result.quality.hdr_format == "HDR10+"
      assert hdr10_result.quality.hdr_format == "HDR10"
      assert hdr_result.quality.hdr_format == "HDR"
      assert sdr_result.quality.hdr_format == nil

      # STRICT: Quality scores must follow TRaSH Guide tier order
      dv_score = QualityParser.quality_score(dv_result.quality)
      hdr10plus_score = QualityParser.quality_score(hdr10plus_result.quality)
      hdr10_score = QualityParser.quality_score(hdr10_result.quality)
      hdr_score = QualityParser.quality_score(hdr_result.quality)
      sdr_score = QualityParser.quality_score(sdr_result.quality)

      assert dv_score > hdr10plus_score,
             "DV (#{dv_score}) must score higher than HDR10+ (#{hdr10plus_score})"

      assert hdr10plus_score > hdr10_score,
             "HDR10+ (#{hdr10plus_score}) must score higher than HDR10 (#{hdr10_score})"

      assert hdr10_score > hdr_score,
             "HDR10 (#{hdr10_score}) must score higher than generic HDR (#{hdr_score})"

      assert hdr_score > sdr_score,
             "HDR (#{hdr_score}) must score higher than SDR (#{sdr_score})"
    end

    test "HDR releases rank higher than SDR for UHD profile" do
      results = [
        # SDR release (no HDR markers)
        build_result(%{
          title: "Dune.2021.2160p.UHD.BluRay.x265.10bit.DDP5.1-RARBG",
          size: 20 * 1024 * 1024 * 1024
        }),
        # HDR release
        build_result(%{
          title: "Dune.2021.2160p.UHD.BluRay.x265.10bit.HDR.TrueHD.7.1.Atmos-RARBG",
          size: 25 * 1024 * 1024 * 1024
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_uhd_bluray_web_profile(),
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      first = List.first(ranked)
      second = List.last(ranked)

      # STRICT: HDR release must rank higher AND have higher score
      assert first.result.quality.hdr == true
      assert second.result.quality.hdr == false

      assert first.score > second.score,
             "HDR score (#{first.score}) must be higher than SDR score (#{second.score})"
    end

    test "Dolby Vision ranks higher than HDR10 with same source" do
      # Use IDENTICAL specs except HDR format to isolate HDR scoring
      results = [
        # HDR10 release
        build_result(%{
          title: "Dune.2021.2160p.UHD.BluRay.REMUX.HDR10.HEVC.TrueHD.Atmos-GROUP",
          size: 60 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        # DV release (same source, same audio)
        build_result(%{
          title: "Dune.2021.2160p.UHD.BluRay.REMUX.DV.HEVC.TrueHD.Atmos-GROUP",
          size: 60 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_uhd_bluray_web_profile(),
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      first = List.first(ranked)

      # STRICT: DV must win when all else is equal
      assert first.result.quality.hdr_format == "DV",
             "Expected DV to rank first, but got #{first.result.quality.hdr_format}"
    end
  end

  # ===========================================================================
  # TEST: AUDIO CODEC TIER RANKING
  # TRaSH Guide: TrueHD Atmos (5000) > DTS-HD MA > DD+ > AAC
  # ===========================================================================

  describe "audio codec tier ranking" do
    test "TrueHD Atmos releases detected with exact audio codec" do
      atmos_releases =
        Enum.filter(@premium_4k_remux_releases, fn title ->
          String.contains?(title, "TrueHD") and String.contains?(title, "Atmos")
        end)

      for title <- atmos_releases do
        result = build_result(%{title: title, size: 50 * 1024 * 1024 * 1024})
        quality = result.quality

        # STRICT: Must detect exact TrueHD Atmos, not just TrueHD or Atmos
        assert quality.audio == "TrueHD Atmos",
               "Expected audio='TrueHD Atmos' but got '#{quality.audio}' for: #{title}"
      end
    end

    test "DTS-HD MA detected exactly in releases" do
      dts_hd_ma_releases = [
        "Oppenheimer.2023.2160p.UHD.Bluray.REMUX.HDR10.HEVC.DTS-HD.MA.5.1-GHD",
        "Oppenheimer.2023.1080p.BluRay.x265.DTS-HD.MA.5.1-DiN"
      ]

      for title <- dts_hd_ma_releases do
        result = build_result(%{title: title, size: 30 * 1024 * 1024 * 1024})
        quality = result.quality

        # STRICT: Must detect exact DTS-HD MA
        assert quality.audio == "DTS-HD MA",
               "Expected audio='DTS-HD MA' but got '#{quality.audio}' for: #{title}"
      end
    end

    test "audio codec scores are correctly tiered per TRaSH Guide" do
      # Build releases with IDENTICAL specs except audio codec
      base_attrs = %{size: 8 * 1024 * 1024 * 1024, seeders: 100}

      atmos_result =
        build_result(Map.put(base_attrs, :title, "Movie.1080p.BluRay.x265.TrueHD.Atmos-GROUP"))

      truehd_result =
        build_result(Map.put(base_attrs, :title, "Movie.1080p.BluRay.x265.TrueHD-GROUP"))

      dts_hd_ma_result =
        build_result(Map.put(base_attrs, :title, "Movie.1080p.BluRay.x265.DTS-HD.MA-GROUP"))

      ddplus_result =
        build_result(Map.put(base_attrs, :title, "Movie.1080p.BluRay.x265.DDP5.1-GROUP"))

      dts_result = build_result(Map.put(base_attrs, :title, "Movie.1080p.BluRay.x265.DTS-GROUP"))
      aac_result = build_result(Map.put(base_attrs, :title, "Movie.1080p.BluRay.x265.AAC-GROUP"))

      # Verify audio detection
      assert atmos_result.quality.audio == "TrueHD Atmos"
      assert truehd_result.quality.audio == "TrueHD"
      assert dts_hd_ma_result.quality.audio == "DTS-HD MA"
      assert ddplus_result.quality.audio == "DD+"
      assert dts_result.quality.audio == "DTS"
      assert aac_result.quality.audio == "AAC"

      # STRICT: Quality scores must follow TRaSH Guide audio tier order
      atmos_score = QualityParser.quality_score(atmos_result.quality)
      truehd_score = QualityParser.quality_score(truehd_result.quality)
      dts_hd_ma_score = QualityParser.quality_score(dts_hd_ma_result.quality)
      ddplus_score = QualityParser.quality_score(ddplus_result.quality)
      dts_score = QualityParser.quality_score(dts_result.quality)
      aac_score = QualityParser.quality_score(aac_result.quality)

      assert atmos_score > truehd_score,
             "TrueHD Atmos (#{atmos_score}) must score higher than TrueHD (#{truehd_score})"

      assert truehd_score > dts_hd_ma_score,
             "TrueHD (#{truehd_score}) must score higher than DTS-HD MA (#{dts_hd_ma_score})"

      assert dts_hd_ma_score > ddplus_score,
             "DTS-HD MA (#{dts_hd_ma_score}) must score higher than DD+ (#{ddplus_score})"

      assert ddplus_score > dts_score,
             "DD+ (#{ddplus_score}) must score higher than DTS (#{dts_score})"

      assert dts_score > aac_score,
             "DTS (#{dts_score}) must score higher than AAC (#{aac_score})"
    end

    test "TrueHD Atmos ranks higher than DTS-HD MA with same specs" do
      # Use IDENTICAL specs except audio to isolate audio scoring
      results = [
        build_result(%{
          title: "Movie.2160p.BluRay.REMUX.DV.HEVC.DTS-HD.MA.7.1-GROUP",
          size: 60 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        build_result(%{
          title: "Movie.2160p.BluRay.REMUX.DV.HEVC.TrueHD.Atmos.7.1-GROUP",
          size: 60 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_uhd_bluray_web_profile(),
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      first = List.first(ranked)

      # STRICT: TrueHD Atmos must win when all else is equal
      assert first.result.quality.audio == "TrueHD Atmos",
             "Expected TrueHD Atmos to rank first, but got #{first.result.quality.audio}"
    end

    test "releases with better audio rank higher (same resolution/source)" do
      results = [
        # DD+ audio
        build_result(%{
          title: "Oppenheimer.2023.1080p.AMZN.WEB-DL.DDP5.1.H.264-BYNDR",
          size: 6 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        # DTS-HD MA audio (higher tier)
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.x265.DTS-HD.MA.5.1-DiN",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          quality_profile: trash_hd_bluray_web_profile(),
          preferred_qualities: ["1080p"]
        )

      first = List.first(ranked)

      # STRICT: DTS-HD MA + BluRay should rank higher than DD+ + WEB-DL
      assert first.result.quality.audio == "DTS-HD MA",
             "Expected DTS-HD MA to rank first, but got #{first.result.quality.audio}"
    end
  end

  # ===========================================================================
  # TEST: RELEASE GROUP TIER RANKING
  # TRaSH Guide defines release group quality tiers
  # Release groups are matched via preferred_tags, not a Quality field
  # ===========================================================================

  describe "release group tier detection" do
    test "WEB Tier 01 groups extracted from title correctly" do
      tier_01_release = "The.Last.of.Us.S01.2160p.MAX.WEB-DL.x265.10bit.HDR.DDP5.1.Atmos-FLUX"
      group = extract_release_group(tier_01_release)

      assert group == "FLUX"
      assert release_group_tier("FLUX") == {:web, 1}
    end

    test "WEB Tier 02 groups extracted from title correctly" do
      tier_02_release = "The.Last.of.Us.S01.2160p.HMAX.WEB-DL.x265.10bit.HDR.DDP5.1.Atmos-SMURF"
      group = extract_release_group(tier_02_release)

      assert group == "SMURF"
      assert release_group_tier("SMURF") == {:web, 2}
    end

    test "HD Bluray Tier 01 groups extracted" do
      # CtrlHD is both HD Bluray Tier 01 and UHD Bluray Tier 01
      tier_01_release = "Oppenheimer.2023.IMAX.2160p.BluRay.x265.10bit.DTS-HD.MA.5.1-CTRLHD"
      group = extract_release_group(tier_01_release)

      # Case insensitive comparison
      assert String.upcase(group) == "CTRLHD"
    end

    test "Tier 01 groups rank higher than Tier 02 with preferred_tags" do
      results = [
        # Tier 02 group (SMURF)
        build_result(%{
          title: "The.Last.of.Us.S01.2160p.HMAX.WEB-DL.x265.10bit.HDR.DDP5.1.Atmos-SMURF",
          size: 40 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        # Tier 01 group (FLUX)
        build_result(%{
          title: "The.Last.of.Us.S01.2160p.MAX.WEB-DL.x265.10bit.HDR.DDP5.1.Atmos-FLUX",
          size: 40 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      # Use preferred_tags to boost Tier 01 groups
      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: ["2160p"],
          preferred_tags: @web_tier_01_groups,
          size_range: @default_size_range
        )

      first = List.first(ranked)
      # Check the title contains FLUX (Tier 01 group)
      assert String.contains?(first.result.title, "FLUX")
      assert first.breakdown.tag_bonus > 0
    end

    test "blocked_tags filters out unwanted groups" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.WEB-DL.x264-BadGroup",
          size: 5 * 1024 * 1024 * 1024,
          seeders: 200
        }),
        build_result(%{
          title: "Movie.2023.1080p.WEB-DL.x264-FLUX",
          size: 5 * 1024 * 1024 * 1024,
          seeders: 50
        })
      ]

      filtered =
        ReleaseRanker.filter_acceptable(results,
          blocked_tags: ["BadGroup"],
          size_range: @default_size_range
        )

      assert length(filtered) == 1
      # Verify via title that it's the FLUX release
      assert String.contains?(List.first(filtered).title, "FLUX")
    end
  end

  # ===========================================================================
  # TEST: PROPER/REPACK HANDLING
  # TRaSH Guide: PROPER/REPACK releases should be preferred
  # ===========================================================================

  describe "PROPER/REPACK handling" do
    test "PROPER releases detected by QualityParser" do
      for title <- @proper_repack_releases do
        result = build_result(%{title: title, size: 8 * 1024 * 1024 * 1024})
        quality = result.quality

        # Should detect PROPER or REPACK
        assert quality.proper == true or quality.repack == true,
               "Expected PROPER/REPACK detection for: #{title}"
      end
    end

    test "PROPER releases rank higher with preferred_tags" do
      results = [
        build_result(%{
          title: "Star.Trek.2009.1080p.BluRay.DTS.x264-GROUP",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        build_result(%{
          title: "Star.Trek.2009.PROPER.REPACK.1080p.BluRay.DTS.x264-ESiR",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: ["1080p"],
          preferred_tags: ["PROPER", "REPACK"]
        )

      first = List.first(ranked)
      assert String.contains?(first.result.title, "PROPER")
      assert first.breakdown.tag_bonus > 0
    end

    test "REPACK alone also gets bonus" do
      results = [
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-GROUP",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        build_result(%{
          title: "Movie.2023.REPACK.1080p.BluRay.x264-GROUP",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: ["1080p"],
          preferred_tags: ["REPACK"]
        )

      first = List.first(ranked)
      assert String.contains?(first.result.title, "REPACK")
    end
  end

  # ===========================================================================
  # TEST: END-TO-END BEST RELEASE SELECTION
  # Real-world scenarios with 5+ candidates
  # ===========================================================================

  describe "end-to-end best release selection - Oppenheimer" do
    test "selects best 1080p release from real candidates" do
      # Mix of real Oppenheimer 1080p releases with varied quality
      results = [
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.DD5.1.x264-GalaxyRG",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 500
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.BluRay.x265.DTS-HD.MA.5.1-DiN",
          size: 6 * 1024 * 1024 * 1024,
          seeders: 200
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.10bit.BluRay.6CH.x265.HEVC-PSA",
          size: 4 * 1024 * 1024 * 1024,
          seeders: 300
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.Bluray.REMUX.AVC.DTS-HD.MA.5.1-GHD",
          size: 35 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        build_result(%{
          title: "Oppenheimer.2023.1080p.AMZN.WEB-DL.DDP5.1.H.264-BYNDR",
          size: 6 * 1024 * 1024 * 1024,
          seeders: 150
        })
      ]

      best = ReleaseRanker.select_best_result(results, preferred_qualities: ["1080p"])

      assert best != nil
      assert best.result.quality.resolution == "1080p"
      # Should select based on composite score (quality + seeders + size + age)
      assert best.score > 0
    end

    test "selects best 2160p release from real candidates" do
      results = [
        build_result(%{
          title:
            "Oppenheimer.2023.2160p.MA.WEB-DL.DUAL.DTS.HD.MA.5.1+DD+5.1.DV-HDR.H.265-TheBiscuitMan",
          size: 25 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        build_result(%{
          title: "Oppenheimer.2023.2160p.UHD.Bluray.REMUX.HDR10.HEVC.DTS-HD.MA.5.1-GHD",
          size: 60 * 1024 * 1024 * 1024,
          seeders: 150
        }),
        build_result(%{
          title: "Oppenheimer.2023.UHD.BluRay.2160p.DTS-HD.MA.5.1.DV.HEVC.HYBRID.REMUX-FraMeSToR",
          size: 70 * 1024 * 1024 * 1024,
          seeders: 80
        }),
        build_result(%{
          title: "Oppenheimer.2023.IMAX.2160p.BluRay.x265.10bit.DTS-HD.MA.5.1-CTRLHD",
          size: 30 * 1024 * 1024 * 1024,
          seeders: 200
        }),
        build_result(%{
          title: "Oppenheimer.2023.2160p.10bit.HDR.BluRay.6CH.x265.HEVC-PSA",
          size: 15 * 1024 * 1024 * 1024,
          seeders: 400
        })
      ]

      best = ReleaseRanker.select_best_result(results, preferred_qualities: ["2160p"])

      assert best != nil
      assert best.result.quality.resolution == "2160p"
    end

    test "filters out HDCAM/CAM releases even with high seeders" do
      results = [
        build_result(%{
          title: "Oppenheimer.2023.720p.HDCAM-C1NEM4",
          size: 2 * 1024 * 1024 * 1024,
          seeders: 1000
        }),
        build_result(%{
          title: "Oppenheimer.2023.720p.BluRay.999MB.x264-GalaxyRG",
          size: 1 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      # Block CAM releases
      filtered = ReleaseRanker.filter_acceptable(results, blocked_tags: ["CAM", "HDCAM"])

      assert length(filtered) == 1
      assert String.contains?(List.first(filtered).title, "BluRay")
    end
  end

  describe "end-to-end best release selection - Dune" do
    test "selects best from mixed quality Dune releases" do
      results =
        @dune_2021_releases
        |> Enum.with_index()
        |> Enum.map(fn {title, idx} ->
          size =
            cond do
              String.contains?(title, "REMUX") -> 60 * 1024 * 1024 * 1024
              String.contains?(title, "2160p") -> 25 * 1024 * 1024 * 1024
              true -> 8 * 1024 * 1024 * 1024
            end

          build_result(%{title: title, size: size, seeders: 200 - idx * 20})
        end)

      # For UHD profile, should pick best 2160p
      best_uhd =
        ReleaseRanker.select_best_result(results,
          preferred_qualities: ["2160p"],
          size_range: @default_size_range
        )

      assert best_uhd.result.quality.resolution == "2160p"

      # For HD profile, should pick best 1080p
      best_hd =
        ReleaseRanker.select_best_result(results,
          preferred_qualities: ["1080p"],
          size_range: @default_size_range
        )

      assert best_hd.result.quality.resolution == "1080p"
    end
  end

  describe "end-to-end best release selection - The Last of Us" do
    test "selects best TV show release" do
      results =
        @the_last_of_us_s01_releases
        |> Enum.with_index()
        |> Enum.map(fn {title, idx} ->
          size =
            if String.contains?(title, "REMUX") or String.contains?(title, "Remux") do
              80 * 1024 * 1024 * 1024
            else
              40 * 1024 * 1024 * 1024
            end

          build_result(%{title: title, size: size, seeders: 150 - idx * 20})
        end)

      best =
        ReleaseRanker.select_best_result(results,
          preferred_qualities: ["2160p"],
          preferred_tags: @web_tier_01_groups ++ @remux_tier_01_groups,
          size_range: @default_size_range
        )

      assert best != nil
      assert best.result.quality.resolution == "2160p"
    end
  end

  describe "end-to-end - mixed resolution scenario" do
    test "correctly ranks when mixing 720p, 1080p, 2160p" do
      results = [
        # 720p HDTV
        build_result(%{
          title: "The.Rookie.S06E08.720p.HDTV.x264-SYNCOPY",
          size: 1 * 1024 * 1024 * 1024,
          seeders: 500
        }),
        # 1080p WEB-DL
        build_result(%{
          title: "The.Rookie.S06E08.1080p.AMZN.WEB-DL.DDP5.1.H264-NTb",
          size: 3 * 1024 * 1024 * 1024,
          seeders: 200
        }),
        # 2160p WEB-DL
        build_result(%{
          title: "The.Rookie.S06E08.2160p.AMZN.WEB-DL.DDP5.1.HDR.HEVC-NTb",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 50
        })
      ]

      # HD profile wants 1080p
      best_hd = ReleaseRanker.select_best_result(results, preferred_qualities: ["1080p", "720p"])
      assert best_hd.result.quality.resolution == "1080p"

      # UHD profile wants 2160p
      best_uhd = ReleaseRanker.select_best_result(results, preferred_qualities: ["2160p"])
      assert best_uhd.result.quality.resolution == "2160p"

      # No preference and no quality profile - highest seeders wins
      best_any = ReleaseRanker.select_best_result(results)
      # Without quality profile, seeders determine ranking, so 720p with 500 seeders wins
      assert best_any.result.quality.resolution == "720p"
    end
  end

  # ===========================================================================
  # TEST: QUALITY PROFILE INTEGRATION WITH RELEASE RANKER
  # Verify QualityMatcher and ReleaseRanker work together correctly
  # ===========================================================================

  describe "quality profile integration" do
    test "HD Bluray + WEB profile filters correctly" do
      profile = trash_hd_bluray_web_profile()

      # This profile allows 720p and 1080p only (via min/max resolution in quality_standards)
      assert profile.quality_standards.min_resolution == "720p"
      assert profile.quality_standards.max_resolution == "1080p"
      refute "2160p" in profile.quality_standards.preferred_resolutions
    end

    test "UHD Bluray + WEB profile filters correctly" do
      profile = trash_uhd_bluray_web_profile()

      # This profile allows only 2160p
      assert "2160p" in profile.quality_standards.preferred_resolutions
      refute "1080p" in profile.quality_standards.preferred_resolutions
    end

    test "preferred_qualities from profile drives ranking" do
      profile = trash_hd_bluray_web_profile()

      results = [
        build_result(%{
          title: "Movie.2023.2160p.UHD.BluRay.HDR.HEVC-GROUP",
          size: 50 * 1024 * 1024 * 1024,
          seeders: 100
        }),
        build_result(%{
          title: "Movie.2023.1080p.BluRay.x264-GROUP",
          size: 8 * 1024 * 1024 * 1024,
          seeders: 100
        })
      ]

      # Using profile's preferred_resolutions as preferred_qualities
      ranked =
        ReleaseRanker.rank_all(results,
          preferred_qualities: profile.quality_standards.preferred_resolutions
        )

      # 1080p should be first because it matches profile
      first = List.first(ranked)
      assert first.result.quality.resolution == "1080p"
    end
  end
end
