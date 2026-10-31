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
