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
end
