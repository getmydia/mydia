defmodule Mydia.Downloads.StallDetectorTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.StallDetector
  alias Mydia.Downloads.StallDetector.Thresholds

  @grace_minutes 60
  @escalation_minutes 180
  @gap_seconds 360
  @base_time ~U[2026-01-01 12:00:00.000000Z]

  # Convenience wrapper so each test only varies the inputs it cares about.
  defp evaluate(opts) do
    StallDetector.evaluate(
      Keyword.get(opts, :last_progress_at, @base_time),
      Keyword.get(opts, :last_known_bytes, 200_000_000),
      Keyword.get(opts, :last_observed_at, @base_time),
      Keyword.get(opts, :stalled_since, nil),
      Keyword.get(opts, :observed_bytes, 200_000_000),
      %Thresholds{
        grace_minutes: Keyword.get(opts, :grace_minutes, @grace_minutes),
        escalation_minutes: Keyword.get(opts, :escalation_minutes, @escalation_minutes),
        gap_threshold_seconds: Keyword.get(opts, :gap_threshold_seconds, @gap_seconds)
      },
      Keyword.fetch!(opts, :now)
    )
  end

  describe "evaluate/7 — first observation" do
    test "initializes when last_progress_at is nil" do
      assert {:initialize, @base_time} =
               evaluate(last_progress_at: nil, last_observed_at: nil, now: @base_time)
    end

    test "initializes even when bytes are already non-zero (fresh row mid-download)" do
      assert {:initialize, @base_time} =
               evaluate(
                 last_progress_at: nil,
                 last_known_bytes: nil,
                 observed_bytes: 1_000_000,
                 now: @base_time
               )
    end
  end

  describe "evaluate/7 — observation gap reset (AE1, AE2)" do
    test "nil last_observed_at (post-migration row) resets, not stalls" do
      # Even far past the grace window, a row never observed yet just resets.
      way_past = DateTime.add(@base_time, (@grace_minutes + 30) * 60, :second)

      assert {:reset, ^way_past} =
               evaluate(last_observed_at: nil, now: way_past)
    end

    test "gap larger than threshold resets, even with bytes unchanged past grace" do
      # last_observed_at is ~10h stale (outage), elapsed since baseline also huge.
      now = DateTime.add(@base_time, 10 * 60 * 60, :second)
      stale_observed = DateTime.add(@base_time, -(10 * 60 * 60), :second)

      assert {:reset, ^now} =
               evaluate(
                 last_progress_at: @base_time,
                 last_observed_at: stale_observed,
                 now: now
               )
    end

    test "gap within threshold does not reset" do
      # Observed 1 poll (~2min) ago, bytes unchanged but still within grace.
      now = DateTime.add(@base_time, 120, :second)
      observed = DateTime.add(@base_time, 0, :second)

      assert :no_change =
               evaluate(last_observed_at: observed, now: now)
    end

    test "a soft-stalled row that then hits a gap resets and clears the stall" do
      now = DateTime.add(@base_time, 10 * 60 * 60, :second)
      stale_observed = DateTime.add(@base_time, -(10 * 60 * 60), :second)

      assert {:reset, ^now} =
               evaluate(
                 last_observed_at: stale_observed,
                 stalled_since: @base_time,
                 now: now
               )
    end
  end

  describe "evaluate/7 — progress" do
    test "returns :progress when bytes increased (gap within threshold)" do
      now = DateTime.add(@base_time, 120, :second)

      assert {:progress, 300_000_000, ^now} =
               evaluate(
                 last_observed_at: @base_time,
                 last_known_bytes: 200_000_000,
                 observed_bytes: 300_000_000,
                 now: now
               )
    end

    test "treats a byte regression as progress (resets the clock, never stalls)" do
      now = DateTime.add(@base_time, 120, :second)

      assert {:progress, 50, ^now} =
               evaluate(
                 last_observed_at: @base_time,
                 last_known_bytes: 100,
                 observed_bytes: 50,
                 now: now
               )
    end

    test "bytes increase on a soft-stalled row auto-clears via :progress (AE4)" do
      now = DateTime.add(@base_time, 120, :second)

      assert {:progress, 250_000_000, ^now} =
               evaluate(
                 last_observed_at: @base_time,
                 stalled_since: @base_time,
                 last_known_bytes: 200_000_000,
                 observed_bytes: 250_000_000,
                 now: now
               )
    end

    test "treats nil last_known_bytes the same as 0" do
      now = DateTime.add(@base_time, 120, :second)

      assert {:progress, 500, ^now} =
               evaluate(
                 last_observed_at: @base_time,
                 last_known_bytes: nil,
                 observed_bytes: 500,
                 now: now
               )
    end
  end

  describe "evaluate/7 — soft-stall window (AE3)" do
    test "no change when bytes unchanged within grace window" do
      five_minutes_later = DateTime.add(@base_time, 5 * 60, :second)
      observed = DateTime.add(@base_time, 4 * 60, :second)

      assert :no_change =
               evaluate(last_observed_at: observed, now: five_minutes_later)
    end

    test "no change at the exact grace boundary (strict >, not >=)" do
      exactly_grace = DateTime.add(@base_time, @grace_minutes * 60, :second)
      observed = DateTime.add(@base_time, @grace_minutes * 60 - 60, :second)

      assert :no_change =
               evaluate(last_observed_at: observed, now: exactly_grace)
    end

    test "soft-stalls one second past the grace boundary, observed continuously" do
      just_past_grace = DateTime.add(@base_time, @grace_minutes * 60 + 1, :second)
      # Observed recently (no gap) so the gap reset does not pre-empt the stall.
      observed = DateTime.add(@base_time, @grace_minutes * 60 - 60, :second)

      assert {:soft_stall, msg, ^just_past_grace} =
               evaluate(last_observed_at: observed, now: just_past_grace)

      assert msg == "stalled after 60m without progress"
    end

    test "soft-stall message reflects the configured grace window" do
      past_grace = DateTime.add(@base_time, 15 * 60 + 1, :second)
      observed = DateTime.add(@base_time, 15 * 60 - 30, :second)

      assert {:soft_stall, "stalled after 15m without progress", ^past_grace} =
               evaluate(
                 grace_minutes: 15,
                 last_known_bytes: 500,
                 observed_bytes: 500,
                 last_observed_at: observed,
                 now: past_grace
               )
    end
  end

  describe "evaluate/7 — escalation (AE6)" do
    test "holds the soft-stall within the escalation window" do
      # Stalled 2h, escalation threshold is 3h; observed recently (no gap).
      now = DateTime.add(@base_time, 2 * 60 * 60, :second)
      observed = DateTime.add(now, -120, :second)

      assert :no_change =
               evaluate(
                 last_progress_at: @base_time,
                 stalled_since: @base_time,
                 last_observed_at: observed,
                 now: now
               )
    end

    test "no escalation at the exact escalation boundary (strict >)" do
      exactly = DateTime.add(@base_time, @escalation_minutes * 60, :second)
      observed = DateTime.add(exactly, -120, :second)

      assert :no_change =
               evaluate(
                 last_progress_at: @base_time,
                 stalled_since: @base_time,
                 last_observed_at: observed,
                 now: exactly
               )
    end

    test "escalates one second past the escalation threshold" do
      past = DateTime.add(@base_time, @escalation_minutes * 60 + 1, :second)
      observed = DateTime.add(past, -120, :second)

      assert {:escalate, msg, ^past} =
               evaluate(
                 last_progress_at: @base_time,
                 stalled_since: @base_time,
                 last_observed_at: observed,
                 now: past
               )

      assert msg == "no progress for 4h"
    end
  end

  describe "stalled?/1" do
    test "true for the canonical soft-stall message" do
      assert StallDetector.stalled?("stalled after 60m without progress")
    end

    test "false for the escalation message" do
      refute StallDetector.stalled?(StallDetector.escalation_message(60, 180))
    end

    test "false for unrelated error messages" do
      refute StallDetector.stalled?("Import failed: bad path")
      refute StallDetector.stalled?("Removed from download client 'qBit'")
    end

    test "false for nil" do
      refute StallDetector.stalled?(nil)
    end
  end

  describe "stalled_message/1" do
    test "interpolates the grace minutes" do
      assert StallDetector.stalled_message(60) == "stalled after 60m without progress"
      assert StallDetector.stalled_message(5) == "stalled after 5m without progress"
    end
  end

  describe "escalation_message/2" do
    # The old message reported only the escalation window, understating the
    # stall by the entire grace window: a default-config download reaching
    # escalation last moved bytes 240 minutes ago, not 180.
    test "reports the total time without progress, not just the escalation window" do
      assert StallDetector.escalation_message(60, 180) == "no progress for 4h"
    end

    test "renders a sub-hour total in minutes" do
      assert StallDetector.escalation_message(10, 20) == "no progress for 30m"
    end

    test "renders a ragged total with both units" do
      assert StallDetector.escalation_message(45, 90) == "no progress for 2h 15m"
    end

    test "no longer claims to have escalated to a failure" do
      refute StallDetector.escalation_message(60, 180) =~ "escalated"
    end
  end

  describe "escalation_minutes/1" do
    test "is three times the grace window" do
      assert StallDetector.escalation_minutes(60) == 180
      assert StallDetector.escalation_minutes(1440) == 4320
    end
  end
end
