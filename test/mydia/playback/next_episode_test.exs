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

  defp partial(episode_id, pct) do
    %Progress{episode_id: episode_id, watched: false, completion_percentage: pct}
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
  end
end
