defmodule Mydia.Playback.NextEpisodeTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.Episode
  alias Mydia.Playback.NextEpisode
  alias Mydia.Playback.Progress

  defp ep(id, season, number) do
    %Episode{id: id, season_number: season, episode_number: number}
  end

  defp watched(episode_id) do
    %Progress{episode_id: episode_id, watched: true, completion_percentage: 100.0}
  end

  # `position_seconds` is derived from the percentage so a helper-built row is
  # internally consistent. A percentage with no position would sit under the
  # resume floor and read as a stray scrub rather than as real viewing.
  defp partial(episode_id, pct, duration \\ 1400) do
    %Progress{
      episode_id: episode_id,
      watched: false,
      position_seconds: round(duration * pct / 100),
      duration_seconds: duration,
      completion_percentage: pct
    }
  end

  describe "determine/2" do
    test "returns start when there is no progress at all" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]

      assert {:start, %Episode{id: "a"}} = NextEpisode.determine(episodes, %{})
    end

    test "returns continue for an in-progress episode" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]
      progress = %{"a" => partial("a", 25.0)}

      assert {:continue, %Episode{id: "a"}} = NextEpisode.determine(episodes, progress)
    end

    test "returns next for the episode after a watched one" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]
      progress = %{"a" => watched("a")}

      assert {:next, %Episode{id: "b"}} = NextEpisode.determine(episodes, progress)
    end

    test "returns all_watched when every episode is watched" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]
      progress = %{"a" => watched("a"), "b" => watched("b")}

      assert :all_watched = NextEpisode.determine(episodes, progress)
    end

    test "an episode at or past 90 percent is not a continue entry" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]
      progress = %{"a" => partial("a", 95.0)}

      # Not `:continue`, because resuming at 95% would land on the credits.
      # It is still the episode returned, though: only the `watched` flag marks
      # completion here, so the episode comes back as the next thing to play
      # and starts from the beginning.
      #
      # A row in this state is reachable in production. `Progress.changeset/3`
      # auto-marks watched at 90%, but a sync passing `authoritative_watched:
      # true` preserves the remote's own unwatched flag at any percentage.
      assert {:next, %Episode{id: "a"}} = NextEpisode.determine(episodes, progress)
    end

    test "a few seconds on a much later episode does not outrank the first unwatched one" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2), ep("c", 1, 3), ep("d", 3, 6)]

      progress = %{
        "a" => watched("a"),
        "b" => watched("b"),
        "d" => partial("d", 0.63, 1422)
      }

      assert {:next, %Episode{id: "c"}} = NextEpisode.determine(episodes, progress)
    end

    test "real viewing on a later episode still wins over an earlier unwatched one" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2), ep("c", 1, 3), ep("d", 3, 6)]

      progress = %{
        "a" => watched("a"),
        "b" => watched("b"),
        "d" => partial("d", 30.0, 1422)
      }

      assert {:continue, %Episode{id: "d"}} = NextEpisode.determine(episodes, progress)
    end

    test "a stray scrub on the first unwatched episode still returns that episode" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]
      progress = %{"a" => watched("a"), "b" => partial("b", 0.5, 1400)}

      assert {:next, %Episode{id: "b"}} = NextEpisode.determine(episodes, progress)
    end

    test "a row with no position at all is not a resume point" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]

      progress = %{
        "a" => watched("a"),
        "b" => %Progress{episode_id: "b", watched: false, completion_percentage: 0.0}
      }

      assert {:next, %Episode{id: "b"}} = NextEpisode.determine(episodes, progress)
    end

    test "the resume floor is configurable" do
      episodes = [ep("a", 1, 1), ep("b", 1, 2)]
      progress = %{"a" => partial("a", 5.0, 1400)}

      assert {:next, %Episode{id: "a"}} =
               NextEpisode.determine(episodes, progress, min_position_seconds: 300)
    end
  end
end
