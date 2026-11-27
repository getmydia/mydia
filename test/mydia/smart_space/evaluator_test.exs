defmodule Mydia.SmartSpace.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Mydia.SmartSpace.{Cleanup, Evaluator, Inputs}
  alias Mydia.SmartSpace.Inputs.{Episode, KeepRef, Show, Watch}

  @now ~U[2026-11-20 12:00:00Z]
  @today ~D[2026-11-20]
  @long_ago ~U[2026-11-01 10:00:00Z]
  @show_id "show-1"

  # -- helpers ---------------------------------------------------------------

  defp global(attrs) do
    Map.merge(
      %{enabled: true, unit: "season", grace_days: 7, watched_by: "all_started"},
      Map.new(attrs)
    )
  end

  defp inputs(shows, opts \\ []) do
    %Inputs{
      global: global(Keyword.get(opts, :global, [])),
      selected_user_ids: Keyword.get(opts, :selected, []),
      shows: List.wrap(shows)
    }
  end

  defp show(episodes, watches, attrs \\ []) do
    struct!(
      Show,
      Keyword.merge(
        [
          media_item_id: @show_id,
          title: "The Lantern Keepers",
          episodes: episodes,
          watches: watches
        ],
        attrs
      )
    )
  end

  defp ep(id, season, number, attrs \\ []) do
    struct!(
      Episode,
      Keyword.merge(
        [
          id: id,
          season_number: season,
          episode_number: number,
          air_date: ~D[2026-01-01],
          files: [{"file-" <> id, 100}]
        ],
        attrs
      )
    )
  end

  defp watch(user, episode_id, at \\ @long_ago, watched \\ true) do
    %Watch{user_id: user, episode_id: episode_id, watched: watched, last_watched_at: at}
  end

  # Two-episode season 1, both watched by user "a".
  defp season_one do
    [ep("e1", 1, 1), ep("e2", 1, 2)]
  end

  defp watched_by(user, episodes, at \\ @long_ago) do
    Enum.map(episodes, &watch(user, &1.id, at))
  end

  defp run(inputs), do: Evaluator.eligible(inputs, @now, @today)

  defp days(n), do: n * 86_400

  # -- policies --------------------------------------------------------------

  describe "watched_by all_started" do
    test "every user who started the show has watched: eligible" do
      eps = season_one()
      watches = watched_by("a", eps) ++ watched_by("b", eps)

      assert [%Cleanup{unit: :season, season_number: 1}] = run(inputs(show(eps, watches)))
    end

    test "user b started but unfinished blocks" do
      eps = season_one()
      watches = watched_by("a", eps) ++ [watch("b", "e1"), watch("b", "e2", @long_ago, false)]

      assert run(inputs(show(eps, watches))) == []
    end

    test "user b with an unwatched record on one episode only blocks that episode (episode unit)" do
      eps = season_one()
      watches = watched_by("a", eps) ++ [watch("b", "e1")]

      assert [%Cleanup{episode_ids: ["e1"]}] =
               run(inputs(show(eps, watches), global: [unit: "episode"]))
    end

    test "user c never started does not block" do
      eps = season_one()
      # "c" has no records at all for this show, so is not required.
      other_show =
        show([ep("x1", 1, 1)], [watch("c", "x1", @long_ago, false)], media_item_id: "show-2")

      result = run(inputs([show(eps, watched_by("a", eps)), other_show]))

      assert [%Cleanup{media_item_id: @show_id}] = result
    end

    test "nobody started yields []" do
      assert run(inputs(show(season_one(), []))) == []
    end
  end

  describe "watched_by any" do
    test "one watcher suffices" do
      eps = season_one()
      watches = watched_by("a", eps) ++ [watch("b", "e1", @long_ago, false)]

      assert [%Cleanup{}] = run(inputs(show(eps, watches), global: [watched_by: "any"]))
    end

    test "eligible_at comes from the earliest watched record" do
      eps = [ep("e1", 1, 1)]
      early = ~U[2026-11-02 08:00:00Z]
      late = ~U[2026-11-05 08:00:00Z]
      watches = [watch("a", "e1", late), watch("b", "e1", early)]

      assert [%Cleanup{eligible_at: eligible_at}] =
               run(inputs(show(eps, watches), global: [watched_by: "any", unit: "episode"]))

      assert eligible_at == DateTime.add(early, days(7), :second)
    end

    test "no watched record is not done" do
      eps = [ep("e1", 1, 1)]
      watches = [watch("a", "e1", @long_ago, false)]

      assert run(inputs(show(eps, watches), global: [watched_by: "any"])) == []
    end
  end

  describe "watched_by selected" do
    test "every selected user watched: eligible, other users ignored" do
      eps = season_one()
      watches = watched_by("a", eps) ++ [watch("z", "e1", @long_ago, false)]

      assert [%Cleanup{}] =
               run(inputs(show(eps, watches), global: [watched_by: "selected"], selected: ["a"]))
    end

    test "unstarted selected user blocks" do
      eps = season_one()

      assert run(
               inputs(show(eps, watched_by("a", eps)),
                 global: [watched_by: "selected"],
                 selected: ["a", "b"]
               )
             ) == []
    end

    test "an empty selected list yields []" do
      eps = season_one()

      assert run(
               inputs(show(eps, watched_by("a", eps)),
                 global: [watched_by: "selected"],
                 selected: []
               )
             ) == []
    end

    test ":misconfigured yields []" do
      eps = season_one()

      assert run(
               inputs(show(eps, watched_by("a", eps)),
                 global: [watched_by: "selected"],
                 selected: :misconfigured
               )
             ) == []
    end
  end

  describe "watch records without a timestamp" do
    test "a required watched record with nil last_watched_at is not done" do
      eps = [ep("e1", 1, 1)]
      watches = [watch("a", "e1"), watch("b", "e1", nil)]

      assert run(inputs(show(eps, watches), global: [unit: "episode"])) == []
    end

    test "under any, a watched record with nil last_watched_at cannot start the clock" do
      eps = [ep("e1", 1, 1)]

      assert run(
               inputs(show(eps, [watch("a", "e1", nil)]),
                 global: [watched_by: "any", unit: "episode"]
               )
             ) == []
    end
  end

  # -- units -----------------------------------------------------------------

  describe "units" do
    test "season unit returns one cleanup with all file ids and summed bytes" do
      eps = [
        ep("e1", 1, 1, files: [{"f1", 100}, {"f1b", 50}]),
        ep("e2", 1, 2, files: [{"f2", 250}])
      ]

      assert [cleanup] = run(inputs(show(eps, watched_by("a", eps))))

      assert %Cleanup{
               media_item_id: @show_id,
               title: "The Lantern Keepers",
               unit: :season,
               season_number: 1,
               bytes: 400
             } = cleanup

      assert Enum.sort(cleanup.file_ids) == ["f1", "f1b", "f2"]
      assert Enum.sort(cleanup.episode_ids) == ["e1", "e2"]
    end

    test "season unit: eligible_at follows the latest episode done_at" do
      eps = season_one()
      later = ~U[2026-11-03 10:00:00Z]
      watches = [watch("a", "e1"), watch("a", "e2", later)]

      assert [%Cleanup{eligible_at: at}] = run(inputs(show(eps, watches)))
      assert at == DateTime.add(later, days(7), :second)
    end

    test "season unit splits by season" do
      eps = season_one() ++ [ep("e3", 2, 1)]

      result = run(inputs(show(eps, watched_by("a", eps))))
      assert result |> Enum.map(& &1.season_number) |> Enum.sort() == [1, 2]
    end

    test "episode unit returns one cleanup per done episode" do
      eps = season_one() ++ [ep("e3", 1, 3)]
      watches = [watch("a", "e1"), watch("a", "e2"), watch("a", "e3", @long_ago, false)]

      result = run(inputs(show(eps, watches), global: [unit: "episode"]))

      assert Enum.all?(result, &(&1.unit == :episode and &1.season_number == 1))
      assert result |> Enum.map(& &1.episode_ids) |> Enum.sort() == [["e1"], ["e2"]]
      assert result |> Enum.map(& &1.file_ids) |> Enum.sort() == [["file-e1"], ["file-e2"]]
      assert Enum.all?(result, &(&1.bytes == 100))
    end

    test "results are sorted by eligible_at ascending" do
      eps = [ep("e1", 1, 1), ep("e2", 1, 2), ep("e3", 1, 3)]

      watches = [
        watch("a", "e1", ~U[2026-11-04 00:00:00Z]),
        watch("a", "e2", ~U[2026-11-02 00:00:00Z]),
        watch("a", "e3", ~U[2026-11-03 00:00:00Z])
      ]

      result = run(inputs(show(eps, watches), global: [unit: "episode"]))
      assert Enum.map(result, & &1.episode_ids) == [["e2"], ["e3"], ["e1"]]
    end
  end

  # -- grace -----------------------------------------------------------------

  describe "grace" do
    test "now == eligible_at is included" do
      at = DateTime.add(@now, -days(7), :second)
      eps = [ep("e1", 1, 1)]

      assert [%Cleanup{eligible_at: @now}] =
               run(inputs(show(eps, [watch("a", "e1", at)]), global: [unit: "episode"]))
    end

    test "now == eligible_at - 1s is excluded" do
      at = DateTime.add(@now, -days(7) + 1, :second)
      eps = [ep("e1", 1, 1)]

      assert run(inputs(show(eps, [watch("a", "e1", at)]), global: [unit: "episode"])) == []
    end

    test "grace_days 0 makes a just-watched episode eligible" do
      eps = [ep("e1", 1, 1)]

      assert [%Cleanup{}] =
               run(
                 inputs(show(eps, [watch("a", "e1", @now)]),
                   global: [unit: "episode", grace_days: 0]
                 )
               )
    end

    test "a later last_watched_at (rewatch) moves eligible_at" do
      eps = [ep("e1", 1, 1)]
      first = DateTime.add(@now, -days(10), :second)
      rewatch = DateTime.add(@now, -days(2), :second)

      assert [_] = run(inputs(show(eps, [watch("a", "e1", first)]), global: [unit: "episode"]))

      assert run(inputs(show(eps, [watch("a", "e1", rewatch)]), global: [unit: "episode"])) == []
    end

    test "the latest required user's record sets done_at" do
      eps = [ep("e1", 1, 1)]
      recent = DateTime.add(@now, -days(2), :second)
      watches = [watch("a", "e1"), watch("b", "e1", recent)]

      assert run(inputs(show(eps, watches), global: [unit: "episode"])) == []
    end
  end

  # -- airing ----------------------------------------------------------------

  describe "airing" do
    test "season with an episode airing tomorrow is excluded under the season unit" do
      eps = season_one() ++ [ep("e3", 1, 3, air_date: Date.add(@today, 1), files: [])]

      assert run(inputs(show(eps, watched_by("a", season_one())))) == []
    end

    test "its aired done episodes are included under the episode unit" do
      eps = season_one() ++ [ep("e3", 1, 3, air_date: Date.add(@today, 1), files: [])]

      result = run(inputs(show(eps, watched_by("a", season_one())), global: [unit: "episode"]))
      assert result |> Enum.map(& &1.episode_ids) |> Enum.sort() == [["e1"], ["e2"]]
    end

    test "an episode airing today counts as aired" do
      eps = [ep("e1", 1, 1, air_date: @today)]

      assert [_] = run(inputs(show(eps, watched_by("a", eps))))
    end

    test "air_date nil is excluded under the season unit" do
      eps = season_one() ++ [ep("e3", 1, 3, air_date: nil, files: [])]

      assert run(inputs(show(eps, watched_by("a", season_one())))) == []
    end

    test "air_date nil on a watched episode with files blocks its season" do
      eps = [ep("e1", 1, 1), ep("e2", 1, 2, air_date: nil)]

      assert run(inputs(show(eps, watched_by("a", eps)))) == []
    end

    test "an unaired episode is never eligible on its own under the episode unit" do
      eps = [ep("e1", 1, 1, air_date: nil), ep("e2", 1, 2, air_date: Date.add(@today, 3))]

      assert run(inputs(show(eps, watched_by("a", eps)), global: [unit: "episode"])) == []
    end
  end

  # -- files -----------------------------------------------------------------

  describe "files" do
    test "aired episode without files is not required to be watched" do
      eps = season_one() ++ [ep("e3", 1, 3, files: [], monitored: false)]

      assert [%Cleanup{episode_ids: ids, file_ids: files}] =
               run(inputs(show(eps, watched_by("a", season_one()))))

      assert ids == ["e1", "e2", "e3"]
      assert Enum.sort(files) == ["file-e1", "file-e2"]
    end

    test "an aired, monitored finale without files holds its season" do
      eps = season_one() ++ [ep("e3", 1, 3, files: [], monitored: true)]

      assert run(inputs(show(eps, watched_by("a", season_one())))) == []
    end

    test "the same finale, unmonitored, lets the season through" do
      eps = season_one() ++ [ep("e3", 1, 3, files: [], monitored: false)]

      assert [%Cleanup{season_number: 1}] = run(inputs(show(eps, watched_by("a", season_one()))))
    end

    test "a monitored episode without files does not affect the episode unit" do
      eps = season_one() ++ [ep("e3", 1, 3, files: [], monitored: true)]

      assert [_, _] =
               run(inputs(show(eps, watched_by("a", season_one())), global: [unit: "episode"]))
    end

    test "season with no files yields nothing" do
      eps = [ep("e1", 1, 1, files: []), ep("e2", 1, 2, files: [])]

      assert run(inputs(show(eps, watched_by("a", eps)))) == []
    end

    test "episode with no files yields nothing under the episode unit" do
      eps = [ep("e1", 1, 1, files: [])]

      assert run(inputs(show(eps, watched_by("a", eps)), global: [unit: "episode"])) == []
    end

    test "a nil file size counts as zero bytes" do
      eps = [ep("e1", 1, 1, files: [{"f1", nil}, {"f2", 10}])]

      assert [%Cleanup{bytes: 10}] = run(inputs(show(eps, watched_by("a", eps))))
    end
  end

  # -- exclusions ------------------------------------------------------------

  describe "exclusions" do
    test "season 0 is never eligible (season unit)" do
      eps = [ep("s1", 0, 1), ep("s2", 0, 2)]

      assert run(inputs(show(eps, watched_by("a", eps)))) == []
    end

    test "season 0 is never eligible (episode unit)" do
      eps = [ep("s1", 0, 1)]

      assert run(inputs(show(eps, watched_by("a", eps)), global: [unit: "episode"])) == []
    end

    test "show keep blocks everything" do
      eps = season_one()
      keeps = [%KeepRef{level: :show}]

      for unit <- ["season", "episode"] do
        assert run(inputs(show(eps, watched_by("a", eps), keeps: keeps), global: [unit: unit])) ==
                 []
      end
    end

    test "season keep blocks that season only" do
      eps = season_one() ++ [ep("e3", 2, 1)]
      keeps = [%KeepRef{level: :season, season_number: 1}]

      assert [%Cleanup{season_number: 2}] =
               run(inputs(show(eps, watched_by("a", eps), keeps: keeps)))

      assert [%Cleanup{episode_ids: ["e3"]}] =
               run(
                 inputs(show(eps, watched_by("a", eps), keeps: keeps), global: [unit: "episode"])
               )
    end

    test "episode keep blocks that episode under the episode unit" do
      eps = season_one()
      keeps = [%KeepRef{level: :episode, episode_id: "e1"}]

      assert [%Cleanup{episode_ids: ["e2"]}] =
               run(
                 inputs(show(eps, watched_by("a", eps), keeps: keeps), global: [unit: "episode"])
               )
    end

    test "a malformed keep blocks the whole show" do
      eps = season_one() ++ [ep("e3", 2, 1)]

      for keep <- [
            %KeepRef{level: :decade},
            %KeepRef{level: :season, season_number: nil},
            %KeepRef{level: :episode, episode_id: nil},
            %KeepRef{level: :season, season_number: 2, episode_id: "e3"},
            %KeepRef{level: :episode, episode_id: "e3", season_number: 2}
          ],
          unit <- ["season", "episode"] do
        assert run(inputs(show(eps, watched_by("a", eps), keeps: [keep]), global: [unit: unit])) ==
                 [],
               "expected #{inspect(keep)} to block the show under the #{unit} unit"
      end
    end

    test "an episode keep under the season unit blocks the whole season" do
      eps = season_one()
      keeps = [%KeepRef{level: :episode, episode_id: "e1"}]

      assert run(inputs(show(eps, watched_by("a", eps), keeps: keeps))) == []
    end

    test "in_flight? episode blocks its season under the season unit" do
      eps = [ep("e1", 1, 1), ep("e2", 1, 2, in_flight?: true)]

      assert run(inputs(show(eps, watched_by("a", eps)))) == []
    end

    test "in_flight? episode without files still blocks its season" do
      eps = season_one() ++ [ep("e3", 1, 3, files: [], in_flight?: true)]

      assert run(inputs(show(eps, watched_by("a", season_one())))) == []
    end

    test "in_flight? episode blocks only itself under the episode unit" do
      eps = [ep("e1", 1, 1), ep("e2", 1, 2, in_flight?: true)]

      assert [%Cleanup{episode_ids: ["e1"]}] =
               run(inputs(show(eps, watched_by("a", eps)), global: [unit: "episode"]))
    end

    test "in_flight_show? blocks everything in the show" do
      eps = season_one()

      for unit <- ["season", "episode"] do
        assert run(
                 inputs(show(eps, watched_by("a", eps), in_flight_show?: true),
                   global: [unit: unit]
                 )
               ) == []
      end
    end
  end

  # -- rules -----------------------------------------------------------------

  describe "rules" do
    test "override custom with global disabled applies" do
      eps = season_one()
      override = %{mode: "custom", unit: "episode", grace_days: 0}

      result =
        run(inputs(show(eps, watched_by("a", eps), override: override), global: [enabled: false]))

      assert length(result) == 2
      assert Enum.all?(result, &(&1.unit == :episode))
    end

    test "override custom grace replaces the global grace" do
      eps = [ep("e1", 1, 1)]
      at = DateTime.add(@now, -days(3), :second)
      override = %{mode: "custom", unit: "season", grace_days: 30}

      assert run(inputs(show(eps, [watch("a", "e1", at)], override: override))) == []

      override = %{mode: "custom", unit: "season", grace_days: 2}
      assert [_] = run(inputs(show(eps, [watch("a", "e1", at)], override: override)))
    end

    test "override off with global enabled skips" do
      eps = season_one()

      assert run(inputs(show(eps, watched_by("a", eps), override: %{mode: "off"}))) == []
    end

    test "no override with global disabled skips" do
      eps = season_one()

      assert run(inputs(show(eps, watched_by("a", eps)), global: [enabled: false])) == []
    end

    test "custom override missing its unit or grace skips" do
      eps = season_one()

      for override <- [
            %{mode: "custom", unit: nil, grace_days: 7},
            %{mode: "custom", unit: "season", grace_days: nil},
            %{mode: "custom", unit: "decade", grace_days: 7},
            %{mode: "custom", unit: "season", grace_days: -1}
          ] do
        assert run(inputs(show(eps, watched_by("a", eps), override: override))) == []
      end
    end

    test "an unknown global unit or watched_by yields []" do
      eps = season_one()

      assert run(inputs(show(eps, watched_by("a", eps)), global: [unit: "decade"])) == []
      assert run(inputs(show(eps, watched_by("a", eps)), global: [watched_by: "whoever"])) == []
    end
  end

  describe "effective_rule/2" do
    test "custom returns its unit and grace" do
      s = show([], [], override: %{mode: "custom", unit: "episode", grace_days: 3})

      assert Evaluator.effective_rule(inputs(s, global: [enabled: false]), s) ==
               %{unit: "episode", grace_days: 3}
    end

    test "off returns nil" do
      s = show([], [], override: %{mode: "off", unit: nil, grace_days: nil})
      assert Evaluator.effective_rule(inputs(s), s) == nil
    end

    test "inherit returns the global rule when enabled, nil when disabled" do
      s = show([], [])

      assert Evaluator.effective_rule(inputs(s), s) == %{unit: "season", grace_days: 7}
      assert Evaluator.effective_rule(inputs(s, global: [enabled: false]), s) == nil
    end
  end
end
