defmodule MydiaWeb.SeedingComponentsTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.SeedingGoal
  alias MydiaWeb.SeedingComponents

  defp goal(seeding_time, required_seed_time) do
    %SeedingGoal{
      tracker: "Velvet Lantern",
      required_seed_time: required_seed_time,
      seeding_time: seeding_time,
      met?: false
    }
  end

  describe "chip_text/1" do
    test "keeps the remainder of a time that is not whole hours or days" do
      # 75 minutes against a 90 minute goal must not read as "1h / 1h".
      assert SeedingComponents.chip_text(goal(75 * 60, 90 * 60)) == "1h 15m / 1h 30m"
      assert SeedingComponents.chip_text(goal(25 * 3600, 36 * 3600)) == "1d 1h / 1d 12h"
    end

    test "never rounds a ratio or a time up to the goal" do
      assert SeedingComponents.chip_text(%SeedingGoal{required_ratio: 1.0, ratio: 0.999}) ==
               "0.99 / 1.0"

      assert SeedingComponents.chip_text(goal(60, 61)) == "1m / 1m 1s"
    end

    test "shows whole units without empty parts" do
      assert SeedingComponents.chip_text(goal(86_400, 3 * 86_400)) == "1d / 3d"
      assert SeedingComponents.chip_text(goal(30, 86_400 + 30 * 60)) == "30s / 1d 30m"
    end
  end

  describe "unknown progress" do
    test "the chip shows an unknown seed time or ratio as ?" do
      assert SeedingComponents.chip_text(goal(nil, 3 * 86_400)) == "? / 3d"

      assert SeedingComponents.chip_text(%SeedingGoal{required_ratio: 1.0, ratio: nil}) ==
               "? / 1.0"
    end

    test "the warning never claims a ratio it does not know" do
      row = %{
        indexer: "Velvet Lantern",
        status: "unknown",
        in_client?: nil,
        metadata: %{"tracker_terms" => %{"minimum_ratio" => 1.0}},
        ratio: 0.0,
        seeding_time: nil
      }

      text = SeedingComponents.removal_warning_text(row)
      assert text =~ "cannot read this download's ratio or seed time"
      refute text =~ "0.00"
      assert text =~ "hit-and-run"

      seeded = %{row | seeding_time: 7200}

      assert SeedingComponents.removal_warning_text(seeded) =~
               "seeded for 2h; its ratio is unknown"
    end

    test "a known ratio with an unknown seed time" do
      row = %{
        status: "paused",
        metadata: %{"tracker_terms" => %{"minimum_ratio" => 1.0}},
        ratio: 0.4,
        seeding_time: nil
      }

      assert SeedingComponents.removal_warning_text(row) =~ "at a ratio of 0.40."
    end
  end

  describe "with an operator seeding target" do
    @private_unknown %{
      indexer: "Velvet Lantern",
      status: "seeding",
      download_client: Mydia.Downloads.BuiltIn.name(),
      metadata: %{"tracker_terms" => %{"private" => true}},
      ratio: 5.0,
      seeding_time: 10_000_000,
      in_client?: true
    }

    @mixed %{
      indexer: "Velvet Lantern",
      status: "seeding",
      download_client: Mydia.Downloads.BuiltIn.name(),
      metadata: %{
        "tracker_terms" => %{"minimum_ratio" => 1.0, "minimum_seed_time" => 72 * 3600}
      },
      ratio: 1.1,
      seeding_time: 80 * 3600,
      in_client?: true
    }

    defp goal_for(row, target),
      do: SeedingGoal.for_download(row, now: ~U[2026-11-14 00:00:00Z], target: target)

    test "a private tracker with unknown rules is not given the target's numbers" do
      goal = goal_for(@private_unknown, %{ratio: 0.0, seed_time: nil})

      # The target's numbers appear only after the "target" marker.
      assert SeedingComponents.chip_text(goal) == "Private, kept seeding · target 5.00 / 0.0"

      text = removal_text(goal)
      assert text =~ "Velvet Lantern is a private tracker and its seeding rules are unknown."
      assert text =~ "seeding target"
      refute text =~ "requires a ratio of 0.0"
    end

    test "the tracker requirement and the target are shown apart" do
      goal = goal_for(@mixed, %{ratio: 2.0, seed_time: nil})

      assert SeedingComponents.chip_text(goal) ==
               "1.10 / 1.0 · 3d 8h / 3d · target 1.10 / 2.0"

      text = removal_text(goal)
      assert text =~ "Velvet Lantern requires a ratio of 1.0 or 3d of seeding."
      refute text =~ "requires a ratio of 2.0"
      assert text =~ "seeding target"
      assert text =~ "ratio of 2.0"
    end

    test "a target without tracker terms is only the target" do
      row = %{@mixed | metadata: %{}}
      goal = goal_for(row, %{ratio: 2.0, seed_time: 4 * 86_400})

      chip = SeedingComponents.chip_text(goal)
      assert chip == "target 1.10 / 2.0 · 3d 8h / 4d"
      refute removal_text(goal) =~ "requires"
    end

    test "the tooltip of a target-only row names the target, not the tracker" do
      row = %{@mixed | metadata: %{}}

      unmet = goal_for(row, %{ratio: 2.0, seed_time: nil})

      assert SeedingComponents.chip_title(unmet) ==
               "Kept in the download client until the seeding target is met"

      met = goal_for(row, %{ratio: 1.0, seed_time: nil})
      assert SeedingComponents.chip_title(met) == "The seeding target is met"
    end

    test "tracker rows keep the tracker wording in the tooltip" do
      assert SeedingComponents.chip_title(goal_for(@mixed, %{ratio: 2.0, seed_time: nil})) =~
               "Velvet Lantern's seeding goal"

      assert SeedingComponents.chip_title(
               goal_for(@private_unknown, %{ratio: 0.0, seed_time: nil})
             ) =~
               "Velvet Lantern's seeding goal"
    end

    defp removal_text(%SeedingGoal{} = goal),
      do: SeedingComponents.goal_warning_text(goal)
  end

  test "the removal warning states the exact required time" do
    row = %{
      indexer: "Velvet Lantern",
      status: "seeding",
      metadata: %{"tracker_terms" => %{"minimum_seed_time" => 90 * 60}},
      ratio: 0.1,
      seeding_time: 75 * 60
    }

    text = SeedingComponents.removal_warning_text(row)
    assert text =~ "Velvet Lantern requires 1h 30m of seeding."
    assert text =~ "after 1h 15m of seeding"
  end
end
