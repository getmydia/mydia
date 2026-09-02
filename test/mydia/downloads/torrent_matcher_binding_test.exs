defmodule Mydia.Downloads.TorrentMatcherBindingTest do
  @moduledoc """
  TargetContext binding (U3): each shortlisted candidate is re-parsed bound to
  its TargetContext, and the parser's binding signals act as gates. The release
  name lives in `original_filename`, which the binding step re-parses.
  """
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.TorrentMatcher
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  import Mydia.Factory

  defp parsed(attrs) do
    defaults = %{type: :tv_show, confidence: 0.9, quality: Quality.empty()}
    struct!(ParsedFileInfo, Map.merge(defaults, Map.new(attrs)))
  end

  describe "wrong-show guard (binding_suspect demotion)" do
    test "a release whose own name binds to a different show is demoted below the match threshold" do
      show = insert(:media_item, %{type: "tv_show", title: "From", monitored: true})
      insert(:episode, %{media_item: show, season_number: 4, episode_number: 7})

      # base title-similarity is computed from `title` ("From" -> 1.0, would match),
      # but the binding step re-parses `original_filename`, whose real title
      # ("Shark Tank India") does not bind to "From" -> binding_suspect -> demote.
      info =
        parsed(
          title: "From",
          season: 4,
          episodes: [7],
          original_filename: "Shark.Tank.India.S04E07.1080p.WEB.h264-GROUP.mkv"
        )

      assert {:error, :no_match_found} = TorrentMatcher.find_match(info)
    end

    test "a consistent release still matches cleanly (binding confirms)" do
      show = insert(:media_item, %{type: "tv_show", title: "From", monitored: true})
      episode = insert(:episode, %{media_item: show, season_number: 4, episode_number: 7})

      info =
        parsed(
          title: "From",
          season: 4,
          episodes: [7],
          original_filename: "From.S04E07.1080p.WEB.h264-GROUP.mkv"
        )

      assert {:ok, match} = TorrentMatcher.find_match(info)
      assert match.media_item.id == show.id
      assert match.episode.id == episode.id
    end
  end

  describe "season is not used as a download veto" do
    test "a next-season release still matches the show (season not penalized)" do
      show = insert(:media_item, %{type: "tv_show", title: "From", monitored: true})

      for s <- 1..4,
          do: insert(:episode, %{media_item: show, season_number: s, episode_number: 1})

      # Season 5 is absent from the library (the normal download case). The show
      # must still match; only the episode lookup fails, proving the show was not
      # demoted by :season_out_of_range.
      info =
        parsed(
          title: "From",
          season: 5,
          episodes: [1],
          original_filename: "From.S05E01.1080p.WEB.h264-GROUP.mkv"
        )

      assert {:error, :episode_not_found} = TorrentMatcher.find_match(info)
    end

    test "a missing middle-season release still matches the show" do
      show = insert(:media_item, %{type: "tv_show", title: "From", monitored: true})
      # Library has S01 and S03 episodes; S02 is missing (a gap the user wants).
      insert(:episode, %{media_item: show, season_number: 1, episode_number: 1})
      insert(:episode, %{media_item: show, season_number: 3, episode_number: 1})

      info =
        parsed(
          title: "From",
          season: 2,
          episodes: [1],
          original_filename: "From.S02E01.1080p.WEB.h264-GROUP.mkv"
        )

      # Show matches (not penalized); episode S02E01 isn't in the library yet.
      assert {:error, :episode_not_found} = TorrentMatcher.find_match(info)
    end
  end

  describe "binding tiebreak" do
    test "does not raise the confidence it reports" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "Zephyr Station",
          year: 2030,
          monitored: true
        })

      {:ok, parsed} =
        Mydia.Downloads.ReleaseIntake.parse_release("Zephyr.Station.2030.1080p.WEB-DL.x265")

      assert {:ok, match} = TorrentMatcher.find_match(parsed)
      assert match.media_item.id == movie.id

      # An exact title plus an exact year is 0.7 + 0.3. Anything above 1.0 is
      # impossible, and anything above the unbound score means the tiebreak
      # leaked into the stored value.
      assert match.confidence <= 1.0
      assert_in_delta match.confidence, 1.0, 0.0001
    end

    test "a near-year release keeps the base score even though the tiebreak nudges the sort key" do
      movie =
        insert(:media_item, %{
          type: "movie",
          title: "Zephyr Station",
          year: 2030,
          monitored: true
        })

      {:ok, parsed} =
        Mydia.Downloads.ReleaseIntake.parse_release("Zephyr.Station.2031.1080p.WEB-DL.x265")

      assert {:ok, match} = TorrentMatcher.find_match(parsed)
      assert match.media_item.id == movie.id

      # Exact title (0.7) + a one-year-off year (+0.15) puts the base at 0.85:
      # above the 0.8 match threshold, below the 1.0 clamp, so the tiebreak has
      # room to move it. binding_confidence is 1.0 here (release title and
      # target title both "Zephyr Station"), so the old code stored
      # min(1.0, 0.85 + 1.0 * 0.05) = 0.90. If the nudge ever leaks back into
      # the stored confidence, this assertion catches it; the clamp test above
      # cannot, since 1.0 + anything still clamps to 1.0.
      assert_in_delta match.confidence, 0.85, 0.0001
    end
  end
end
