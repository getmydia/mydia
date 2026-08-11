defmodule Mydia.WatchSync.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Mydia.WatchSync.Reconciler

  defp at(offset), do: DateTime.add(~U[2026-01-01 00:00:00Z], offset, :second)

  defp side(watched, position \\ nil, time \\ nil) do
    %{watched: watched, position_seconds: position, at: time}
  end

  describe "watched flag" do
    test "no snapshot unions both sides so a first sync never deletes history" do
      assert {:pull, %{watched: true}} =
               Reconciler.resolve(side(false), side(true), nil)

      assert {:push, %{watched: true}} =
               Reconciler.resolve(side(true), side(false), nil)
    end

    test "remote changed alone pulls" do
      snapshot = side(false)
      assert {:pull, %{watched: true}} = Reconciler.resolve(side(false), side(true), snapshot)
    end

    test "local changed alone pushes" do
      snapshot = side(false)
      assert {:push, %{watched: true}} = Reconciler.resolve(side(true), side(false), snapshot)
    end

    test "a local unwatch propagates when the snapshot says it was watched" do
      # The local playback_progress row is gone, so local reads as unwatched.
      # Only the snapshot proves it was ever watched, which is why unwatch
      # propagation is impossible without it.
      snapshot = side(true)
      assert {:push, %{watched: false}} = Reconciler.resolve(side(false), side(true), snapshot)
    end

    test "a remote unwatch propagates" do
      snapshot = side(true)
      assert {:pull, %{watched: false}} = Reconciler.resolve(side(true), side(false), snapshot)
    end

    test "both sides converged independently records only" do
      snapshot = side(false)
      assert {:record_only, _} = Reconciler.resolve(side(true), side(true), snapshot)
    end

    test "nothing changed is a noop" do
      snapshot = side(true)
      assert :noop = Reconciler.resolve(side(true), side(true), snapshot)
    end

    test "only local moving off the snapshot pushes, regardless of timestamps" do
      # Remote still matches the snapshot here, so this is a one-sided change
      # and no timestamp comparison is involved.
      snapshot = %{watched: false, position_seconds: nil, at: at(0)}
      local = %{watched: true, position_seconds: nil, at: at(100)}
      remote = %{watched: false, position_seconds: nil, at: at(50)}

      assert {:push, %{watched: true}} = Reconciler.resolve(local, remote, snapshot)
    end

    test "both sides moving off the snapshot can only converge, never conflict" do
      # A "both changed in opposite directions" conflict is impossible for a
      # boolean: differing from the same snapshot value forces both sides to the
      # same new value. This asserts that property exhaustively rather than
      # carrying an unreachable conflict-resolution branch for a case that
      # cannot occur.
      for snapshot_watched <- [true, false] do
        flipped = not snapshot_watched
        snapshot = %{watched: snapshot_watched, position_seconds: nil, at: at(0)}
        local = %{watched: flipped, position_seconds: nil, at: at(100)}
        remote = %{watched: flipped, position_seconds: nil, at: at(50)}

        assert {:record_only, %{watched: ^flipped}} =
                 Reconciler.resolve(local, remote, snapshot)
      end
    end
  end

  describe "position" do
    test "a position delta below the noise threshold is not propagated" do
      snapshot = %{watched: false, position_seconds: 100, at: at(0)}
      local = %{watched: false, position_seconds: 105, at: at(10)}
      remote = %{watched: false, position_seconds: 100, at: at(0)}

      assert :noop = Reconciler.resolve(local, remote, snapshot)
    end

    test "a meaningful local position delta pushes" do
      snapshot = %{watched: false, position_seconds: 100, at: at(0)}
      local = %{watched: false, position_seconds: 400, at: at(10)}
      remote = %{watched: false, position_seconds: 100, at: at(0)}

      assert {:push, %{position_seconds: 400}} = Reconciler.resolve(local, remote, snapshot)
    end

    test "a position update never resurrects an item both sides agree is watched" do
      snapshot = %{watched: true, position_seconds: 100, at: at(0)}
      local = %{watched: true, position_seconds: 400, at: at(10)}
      remote = %{watched: true, position_seconds: 100, at: at(0)}

      assert {:push, change} = Reconciler.resolve(local, remote, snapshot)
      assert change.watched == true
    end
  end
end
