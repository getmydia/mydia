defmodule MydiaWeb.ActivityLive.DateFilterTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.ActivityLive.DateFilter

  # Local date Oct 23 in Rome (UTC+2), but still Oct 22 in UTC.
  @now ~U[2026-10-22 22:30:00Z]

  test "today starts at local midnight in the viewer's zone" do
    assert DateFilter.opts("today", @now, "Europe/Rome") == [since: ~U[2026-10-22 22:00:00Z]]
    assert DateFilter.opts("today", @now, "Etc/UTC") == [since: ~U[2026-10-22 00:00:00Z]]
  end

  test "yesterday spans the previous local calendar day" do
    assert DateFilter.opts("yesterday", @now, "Europe/Rome") ==
             [since: ~U[2026-10-21 22:00:00Z], until: ~U[2026-10-22 22:00:00Z]]
  end

  test "an instant that is UTC yesterday but local today matches today in Rome only" do
    inserted_at = ~U[2026-10-22 22:10:00Z]

    assert DateFilter.matches?(inserted_at, "today", @now, "Europe/Rome")
    refute DateFilter.matches?(inserted_at, "yesterday", @now, "Europe/Rome")
    assert DateFilter.matches?(inserted_at, "today", @now, "Etc/UTC")
    refute DateFilter.matches?(~U[2026-10-22 21:59:00Z], "today", @now, "Europe/Rome")
  end

  test "matches?/4 agrees with opts/3 for rolling windows and all" do
    assert DateFilter.matches?(~U[2026-10-16 00:00:00Z], "week", @now, "Etc/UTC")
    refute DateFilter.matches?(~U[2026-10-14 00:00:00Z], "week", @now, "Etc/UTC")
    assert DateFilter.matches?(~U[2020-01-01 00:00:00Z], "all", @now, "Etc/UTC")
  end

  test "a midnight that falls in a DST gap resolves to the first valid instant" do
    # Sao Paulo skipped 00:00 on 2018-11-04 (clocks jumped to 01:00, UTC-2).
    now = ~U[2018-11-04 12:00:00Z]
    assert DateFilter.opts("today", now, "America/Sao_Paulo") == [since: ~U[2018-11-04 03:00:00Z]]
  end

  test "an ambiguous midnight resolves to the earlier instant" do
    # Havana repeats 00:00 on 2026-11-01 when clocks fall back; earlier is UTC-4.
    now = ~U[2026-11-01 12:00:00Z]
    assert DateFilter.opts("today", now, "America/Havana") == [since: ~U[2026-11-01 04:00:00Z]]
  end
end
