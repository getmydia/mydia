defmodule Mydia.Playback.StatsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Playback.Stats
  alias Mydia.Repo

  # Events are written through an async path in production. These tests insert
  # rows directly so they assert the aggregation, not the emission.
  defp insert_play(resource_type, inserted_at) do
    Repo.insert!(%Mydia.Events.Event{
      category: "playback",
      type: "playback.started",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      resource_type: resource_type,
      resource_id: Ecto.UUID.generate(),
      severity: :info,
      metadata: %{},
      inserted_at: inserted_at
    })
  end

  describe "plays_by_day/1" do
    test "returns a dense window even with no events" do
      result = Stats.plays_by_day(7)

      assert length(result) == 7
      assert Enum.all?(result, &(&1.movies == 0 and &1.episodes == 0))
    end

    test "returns days oldest first, ending today" do
      result = Stats.plays_by_day(7)

      dates = Enum.map(result, & &1.date)
      assert dates == Enum.sort(dates, Date)
      assert List.last(dates) == Stats.local_today()
    end

    test "splits movies from episodes" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_play("media_item", now)
      insert_play("media_item", now)
      insert_play("episode", now)

      result = Stats.plays_by_day(7)
      today = List.last(result)

      assert today.movies == 2
      assert today.episodes == 1
    end

    test "ignores events outside the window" do
      old = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.truncate(:second)
      insert_play("media_item", old)

      result = Stats.plays_by_day(7)

      assert Enum.all?(result, &(&1.movies == 0))
    end

    test "ignores non-playback event types" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%Mydia.Events.Event{
        category: "playback",
        type: "playback.finished",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        resource_type: "media_item",
        resource_id: Ecto.UUID.generate(),
        severity: :info,
        metadata: %{},
        inserted_at: now
      })

      result = Stats.plays_by_day(7)

      assert Enum.all?(result, &(&1.movies == 0))
    end
  end

  describe "bucket_date/2" do
    test "shifts a UTC timestamp into the local day" do
      # 03:00 UTC under a -5h offset is the previous local day.
      at = ~U[2026-08-12 03:00:00Z]

      assert Stats.bucket_date(at, -5 * 3600) == ~D[2026-08-11]
      assert Stats.bucket_date(at, 0) == ~D[2026-08-12]
    end
  end

  # fetch_events/3 deliberately widens the UTC window by a day on each side so a
  # local-evening play under a negative offset is still fetched. That means rows
  # outside the local window reach the reducer and must be discarded there. If
  # the discard is wrong, plays leak onto days they did not happen on.
  describe "local window boundaries" do
    defp local_at(date, time, offset) do
      date
      |> DateTime.new!(time)
      |> DateTime.add(-offset, :second)
      |> DateTime.truncate(:second)
    end

    test "an event one day before the window is fetched but discarded" do
      offset = Stats.local_utc_offset()
      today = Stats.local_today(offset)
      first_day = Date.add(today, -6)

      insert_play("media_item", local_at(Date.add(first_day, -1), ~T[12:00:00], offset))

      result = Stats.plays_by_day(7)

      assert length(result) == 7
      assert Enum.sum(Enum.map(result, & &1.movies)) == 0
      assert List.first(result).date == first_day
    end

    test "an event dated tomorrow is fetched but discarded" do
      offset = Stats.local_utc_offset()
      today = Stats.local_today(offset)

      insert_play("episode", local_at(Date.add(today, 1), ~T[12:00:00], offset))

      result = Stats.plays_by_day(7)

      assert Enum.sum(Enum.map(result, & &1.episodes)) == 0
      assert List.last(result).date == today
    end

    test "a play at local 23:00 lands on today, not tomorrow" do
      # This is the case local bucketing exists for: prime-time viewing under a
      # negative offset is already tomorrow in UTC.
      offset = Stats.local_utc_offset()
      today = Stats.local_today(offset)

      insert_play("media_item", local_at(today, ~T[23:00:00], offset))

      result = Stats.plays_by_day(7)

      assert List.last(result).date == today
      assert List.last(result).movies == 1
    end

    test "a play at local 00:30 lands on today, not yesterday" do
      offset = Stats.local_utc_offset()
      today = Stats.local_today(offset)

      insert_play("media_item", local_at(today, ~T[00:30:00], offset))

      result = Stats.plays_by_day(7)

      assert List.last(result).movies == 1
      assert Enum.at(result, -2).movies == 0
    end
  end
end
