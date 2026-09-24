defmodule Mydia.Indexers.ReleaseIdentityTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.ReleaseIdentity
  alias Mydia.Indexers.ReleaseIdentity.Target
  alias Mydia.Library.Text

  defp movie(title, year, alts \\ []),
    do: %Target{type: :movie, year: year, keys: Enum.map([title | alts], &Text.match_key/1)}

  defp show(title, alts \\ []),
    do: %Target{type: :tv_show, year: nil, keys: Enum.map([title | alts], &Text.match_key/1)}

  describe "check/2 with a parsed title" do
    test "matches the title whatever the punctuation" do
      assert ReleaseIdentity.check(
               "Moth Man.Far.from.Shore.2029.1080p.BluRay.x265-GROUP",
               movie("Moth-Man: Far From Shore", 2029)
             ) == :match
    end

    test "matches an alternative title" do
      assert ReleaseIdentity.check(
               "Starfall The Lantern And Ash 2031 1080p WEB-DL HEVC x265 5.1 GROUP",
               movie("The Lantern and Ash", 2031, ["Starfall: The Lantern and Ash"])
             ) == :match
    end

    test "rejects a name that only starts with the title" do
      assert ReleaseIdentity.check(
               "Lantern Vale - Lantern Came Over For Dinner (01.06.2031)_1080p.mp4",
               movie("Lantern", 2031)
             ) == {:mismatch, :title}
    end

    test "rejects a different show that shares a word" do
      assert ReleaseIdentity.check(
               "Star.Harbor.Rising.S01E05.1080p.WEB-DL.x264-GROUP",
               show("Star Harbor")
             ) == {:mismatch, :title}
    end

    test "ignores a leading group tag" do
      assert ReleaseIdentity.check(
               "[geckyzz] Smoke Cat - S01E08 [WEB-DL 1080P AVC, AAC][E24BC7C7].mkv",
               show("Smoke Cat")
             ) == :match
    end

    test "matches either side of an AKA" do
      target = movie("The Harbor's Edge", 2031)

      assert ReleaseIdentity.check(
               "The Harbor's Edge AKA Gang feng bian (2031)_1080p.mkv",
               target
             ) == :match

      assert ReleaseIdentity.check(
               "Gang.Feng.Bian.aka.The.Harbors.Edge.2031.1080p.WEB-DL-GROUP",
               target
             ) == :match
    end

    test "matches past a leading title in another script" do
      assert ReleaseIdentity.check(
               "港风边.The.Harbor's.Edge.2031.2160p.WEB-DL.DDP5.1.H265-GROUP",
               movie("The Harbor's Edge", 2031)
             ) == :match
    end

    test "matches past a trailing title in another script" do
      assert ReleaseIdentity.check(
               "The.Harbor's.Edge.港风边.2031.1080p.WEB-DL.x264-GROUP",
               movie("The Harbor's Edge", 2031)
             ) == :match
    end

    test "matches a title containing a word that is also a language tag" do
      assert ReleaseIdentity.check(
               "The.Italian.Harbor.2031.1080p.WEB-DL.x264-GROUP",
               movie("The Italian Harbor", 2031)
             ) == :match

      assert ReleaseIdentity.check(
               "Multi Season Show.S01.COMPLETE.1080p.WEB-DL.x264-GROUP",
               show("Multi Season Show")
             ) == :match
    end

    test "still rejects an AKA whose sides are both other titles" do
      assert ReleaseIdentity.check(
               "Lantern Vale AKA Lantern Heaven (2031)_1080p.mkv",
               movie("Lantern", 2031)
             ) == {:mismatch, :title}
    end

    test "still rejects a Latin title that only starts with the item's" do
      assert ReleaseIdentity.check(
               "港风边.Lantern.Vale.2031.1080p.WEB-DL.x264-GROUP",
               movie("Lantern", 2031)
             ) == {:mismatch, :title}
    end

    test "ignores a leading fullwidth-bracket site tag" do
      target = movie("You and Me Against the Tide", 2031)

      assert ReleaseIdentity.check(
               "【高清影视之家发布 www.example.com】You.and.Me.Against.the.Tide.2031.1080p.AMZN.WEB-DL.H.264-GRP",
               target
             ) == :match

      assert ReleaseIdentity.check(
               "【高清影视之家发布 www.example.com】你我对抗潮水[简繁英字幕].You.and.Me.Against.the.Tide.2031.1080p.AMZN.WEB-DL.H.264-GRP",
               target
             ) == :match

      assert ReleaseIdentity.check(
               "［www.example.com］You.and.Me.Against.the.Tide.2031.1080p.WEB-DL-GRP",
               target
             ) == :match
    end

    test "matches a season pack named by a show's alias" do
      target = show("Quiet Harbor: The Long Tide", ["Quiet Harbor"])

      assert ReleaseIdentity.check(
               "Quiet.Harbor.S02.1080p.BluRay.REMUX.Dual-Audio.AVC.FLAC2.0-GRP",
               target
             ) == :match

      assert ReleaseIdentity.check(
               "Quiet.Harbor.Nights.S02.1080p.WEB-DL-GRP",
               target
             ) == {:mismatch, :title}
    end
  end

  describe "check/2 without a parsed title" do
    test "matches a numeric title the parser reads as a year" do
      assert ReleaseIdentity.check("2043.2031.1080p.BluRay.x264-GROUP", movie("2043", 2031)) ==
               :match
    end

    test "rejects an air-dated name" do
      assert ReleaseIdentity.check(
               "2031-05-12 Lantern Vale (Harbor Chapter 1 Arrival) 1080p.mkv",
               movie("Lantern", 2031)
             ) == {:mismatch, :title}
    end

    test "reads the release year after the matched title" do
      assert ReleaseIdentity.check("2043.1990.1080p.BluRay.x264-GROUP", movie("2043", 2031)) ==
               {:mismatch, :year}
    end
  end

  describe "check/2 year rule" do
    test "a movie accepts a year off by one" do
      assert ReleaseIdentity.check(
               "Glass.Harbor.2030.1080p.WEBRip.x265-GROUP",
               movie("Glass Harbor", 2031)
             ) ==
               :match
    end

    test "a movie rejects a year further away" do
      assert ReleaseIdentity.check(
               "Night.Harbor.1994.1080p.BluRay.x264-GROUP",
               movie("Night Harbor", 2031)
             ) ==
               {:mismatch, :year}
    end

    test "a movie with no release year passes" do
      assert ReleaseIdentity.check(
               "Glass.Harbor.1080p.WEB-DL.x264-GROUP",
               movie("Glass Harbor", 2031)
             ) ==
               :match
    end

    test "a show has no year rule" do
      assert ReleaseIdentity.check(
               "Dark.Lantern.2019.S01E01.1080p.WEB.h264-GROUP",
               %Target{type: :tv_show, year: 2024, keys: ["darklantern"]}
             ) == :match
    end
  end
end
