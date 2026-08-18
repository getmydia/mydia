defmodule Mydia.Library.ReleaseParser.AbsoluteEpisodeTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext

  defp anime_target do
    %TargetContext{
      type: :tv_show,
      title: "Black Clover",
      category: "anime_series",
      max_absolute_number: 170,
      known_seasons: [0, 1]
    }
  end

  defp ordinary_target do
    %TargetContext{
      type: :tv_show,
      title: "Black Clover",
      category: "tv_show",
      max_absolute_number: nil,
      known_seasons: [0, 1]
    }
  end

  test "resolves a bare number for an anime target" do
    result =
      ReleaseParser.parse("[SubsPlease] Black Clover - 170 (1080p) [A1B2C3].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 170
  end

  test "ignores a bare number for a non-anime target" do
    result =
      ReleaseParser.parse(
        "[SubsPlease] Black Clover - 170 (1080p) [A1B2C3].mkv",
        target: ordinary_target()
      )

    assert result.absolute_episode == nil
  end

  test "ignores a bare number above the show's absolute range" do
    result = ReleaseParser.parse("Black Clover - 2049 (1080p).mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "does not treat resolution or codec digits as episodes" do
    result = ReleaseParser.parse("Black Clover 1080p x264 AAC.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "an explicit season marker wins over the bare number" do
    result = ReleaseParser.parse("Black Clover S01E52 1080p.mkv", target: anime_target())

    assert result.season == 1
    assert result.episodes == [52]
    assert result.absolute_episode == nil
  end

  test "ignores a bare number when category is present but not anime" do
    target = %{ordinary_target() | max_absolute_number: 170}

    result =
      ReleaseParser.parse(
        "[SubsPlease] Black Clover - 170 (1080p) [A1B2C3].mkv",
        target: target
      )

    assert result.absolute_episode == nil
  end

  test "does not pick up a numeric title as the episode number" do
    result =
      ReleaseParser.parse("[Erai-raws] 86 - Eighty Six - 12 [1080p].mkv", target: anime_target())

    assert result.absolute_episode == 12
  end

  test "does not pick up a numeric title's leading digits as the episode number" do
    result =
      ReleaseParser.parse("[HorribleSubs] 91 Days - 07 [720p].mkv", target: anime_target())

    assert result.absolute_episode == 7
  end

  test "does not pick up a sequel number in the title as the episode number" do
    result =
      ReleaseParser.parse(
        "[SubsPlease] Log Horizon 2 - 05 (1080p) [ABCDEF].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 5
  end

  test "does not pick up a part number in the title as the episode number" do
    result = ReleaseParser.parse("Black Clover Part 2 - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "does not pick up a frame rate as the episode number" do
    result =
      ReleaseParser.parse("Black Clover 10bit 24 fps - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "does not pick up an audio channel layout as the episode number" do
    result = ReleaseParser.parse("Black Clover FLAC 2.0 - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "resolves a space-separated bare number with no dash at all" do
    result =
      ReleaseParser.parse("[SubsPlease] Black Clover 170 (1080p) [A1B2C3].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 170
  end

  test "resolves a trailing bare number with no other anchors" do
    result = ReleaseParser.parse("Black Clover 170.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves a dot-separated bare number with no dash" do
    result = ReleaseParser.parse("Black Clover.170.1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves a bare number that precedes the dash instead of following it" do
    result = ReleaseParser.parse("Black Clover 05 - 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "prefers the dash-adjacent episode number over a later embedded digit" do
    result =
      ReleaseParser.parse(
        "[Group] Black Clover - 05 - The Title 12 [1080p].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 5
  end

  test "resolves through a compound-dash-split quality tag with no separating dash" do
    result =
      ReleaseParser.parse("Black Clover 170 DTS-HD 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through separate audio words with no separating dash" do
    result = ReleaseParser.parse("Black Clover 170 DTS HD 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through a codec tag with no separating dash" do
    result = ReleaseParser.parse("Black Clover 170 x264 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through a trailing codec tag with no other anchors" do
    result = ReleaseParser.parse("Black Clover 170 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through a trailing audio tag with no other anchors" do
    result = ReleaseParser.parse("Black Clover 170 AAC.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves a low episode number through a trailing audio tag" do
    result = ReleaseParser.parse("Black Clover 05 AAC.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "resolves a low episode number through a trailing codec tag" do
    result = ReleaseParser.parse("Black Clover 05 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  # When the filename is ambiguous, decline. With no dash to say which
  # bare integer is the episode number, guessing risks silently filing
  # episode 170 as episode 2; returning nil costs one manual action.
  test "declines when a second bare number follows the episode number" do
    result = ReleaseParser.parse("Black Clover 170 2 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "declines when a second bare number follows a low episode number" do
    result = ReleaseParser.parse("Black Clover 05 2 1080p.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "declines when the second bare number is not a plausible part number" do
    result = ReleaseParser.parse("Black Clover 170 8 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  # The dash path has the same ambiguity as the no-dash one: a cour or
  # part number can be dash-adjacent too, and taking the first match
  # read this as episode 2.
  test "declines when two bare numbers are both dash-adjacent" do
    result = ReleaseParser.parse("Black Clover - 2 - 170 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "declines when a dash-adjacent cour number precedes a dash-adjacent episode" do
    result = ReleaseParser.parse("Black Clover - 2 - 05.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "resolves when the cour number is not itself dash-adjacent" do
    result = ReleaseParser.parse("Black Clover - Cour 2 - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  # Deliberate recall loss, changed from 5 to nil when the dash path
  # gained the same cardinality bound as the title-zone path. Both `05`
  # and `12` are dash-adjacent here, so the set is ambiguous and the
  # parser declines. It resolved before only because taking the first
  # match happened to pick the right one; taking the last would have
  # been needed for `Black Clover - 2 - 170 HEVC.mkv`, and no positional
  # rule satisfies both. Losing an episode with a numeric title to nil
  # is the accepted price for never inventing an episode number.
  test "declines an episode whose title begins with a dash-adjacent number" do
    result =
      ReleaseParser.parse("[Group] Black Clover - 05 - 12 Days Later.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  # A dash anchor that declines on ambiguity must suppress the match, not
  # hand the decision to the title-zone anchor. When a year or resolution
  # token sits between the two dash candidates, the zone holds exactly one
  # bare digit — the show's sequel/cour number — so falling through
  # resolved these to 4, 2 and 86 respectively. The last is the original
  # round-0 false positive, `86` from `86 - Eighty Six`.
  #
  # These assert nil, not the episode number. Both dash candidates survive
  # filtering in each, so the set is ambiguous and the parser declines, the
  # same as `[Group] Black Clover - 05 - 12 Days Later.mkv` above. Reading
  # 5, 5 and 12 out of them would need "first dash-adjacent", which is
  # precisely the rule that resolved `Black Clover - 2 - 170 HEVC.mkv` to 2.
  test "declines rather than promoting the sequel number when the dash set is ambiguous" do
    target = %{anime_target() | title: "Overlord", max_absolute_number: 52}

    result = ReleaseParser.parse("Overlord 4 (2022) - 05 - 12 Days.mkv", target: target)

    assert result.absolute_episode == nil
  end

  test "declines rather than promoting a cour number past a year token" do
    target = %{anime_target() | title: "Log Horizon", max_absolute_number: 62}

    result =
      ReleaseParser.parse("Log Horizon 2 (2021) - 05 - 12 Days Later.mkv", target: target)

    assert result.absolute_episode == nil
  end

  test "declines rather than promoting a numeric title past a year token" do
    target = %{anime_target() | title: "86"}

    result = ReleaseParser.parse("86 (2021) - 12 - 5 Reasons [1080p].mkv", target: target)

    assert result.absolute_episode == nil
  end

  # Accepted cost of suppressing that fall-through: three shapes that the
  # zone anchor used to rescue now decline. All move toward nil, never
  # toward a wrong number.
  test "declines a dash-adjacent pair split by a parenthesised resolution" do
    result = ReleaseParser.parse("Black Clover - 05 (1080p) - 999.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "declines a dash-adjacent pair split by a bare resolution" do
    result = ReleaseParser.parse("Black Clover - 05 - 1080p - 12.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "declines a dash-adjacent pair split by a resolution, high number first" do
    result = ReleaseParser.parse("Black Clover - 170 - 1080p - 2.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end
end
