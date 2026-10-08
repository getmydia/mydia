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

  describe "merge_remotes/1" do
    test "a single copy passes through" do
      assert Reconciler.merge_remotes([side(true, 30, at(5))]) == side(true, 30, at(5))
    end

    test "any watched copy makes the item watched" do
      merged = Reconciler.merge_remotes([side(false, nil, at(10)), side(true, nil, at(1))])
      assert merged.watched
    end

    test "position and time come from the most recently played copy" do
      merged = Reconciler.merge_remotes([side(false, 900, at(1)), side(false, 120, at(10))])
      assert merged == side(false, 120, at(10))
    end

    test "a dated copy outranks an undated one" do
      merged = Reconciler.merge_remotes([side(false, 900, nil), side(false, 120, at(10))])
      assert merged == side(false, 120, at(10))
    end

    test "with no dates at all the furthest position wins" do
      merged =
        Reconciler.merge_remotes([side(false, 120, nil), side(true, 900, nil), side(false)])

      assert merged == side(true, 900, nil)
    end

    test "extra keys on the inputs are dropped" do
      merged = Reconciler.merge_remotes([Map.put(side(true, 5, at(0)), :remote_id, "x")])
      assert merged == side(true, 5, at(0))
    end
  end
end
