defmodule Mydia.SubsyncTest do
  use ExUnit.Case, async: true

  alias Mydia.Subsync

  defp evenly_spaced(count), do: for(i <- 0..(count - 1), do: {i * 7000, i * 7000 + 2000})

  defp shifted(spans, by), do: Enum.map(spans, fn {s, e} -> {s + by, e + by} end)

  describe "align/2" do
    test "recovers an exact constant shift across the NIF boundary" do
      reference = evenly_spaced(40)
      late = shifted(reference, 2500)

      assert {-2500, score} = Subsync.align(reference, late)
      assert score / length(late) > 0.9
    end

    test "returns a zero offset for an already synced track" do
      reference = evenly_spaced(40)

      assert {0, score} = Subsync.align(reference, reference)
      assert score / length(reference) > 0.9
    end

    test "returns a zero score for empty input" do
      assert {0, +0.0} = Subsync.align([], evenly_spaced(4))
      assert {0, +0.0} = Subsync.align(evenly_spaced(4), [])
    end
  end
end
