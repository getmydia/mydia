defmodule Mydia.Library.SegmentDetection.CorrelatorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.SegmentDetection.Correlator
  alias Mydia.Library.SegmentDetection.Correlator.Match

  # Deterministic pseudo-random uint32 stream. Seeded by `seed` so each call
  # with a different seed yields a different but reproducible stream. We avoid
  # :rand so tests never depend on global RNG state.
  defp noise(count, seed) do
    Enum.map(1..count, fn i ->
      :erlang.phash2({seed, i}, 4_294_967_296)
    end)
  end

  # Flip `n` bits in the low 32 of an integer, deterministically.
  defp perturb(value, n) do
    Enum.reduce(0..(n - 1), value, fn bit, acc ->
      Bitwise.bxor(acc, Bitwise.bsl(1, bit))
    end)
  end

  describe "best_match/3" do
    test "finds a shared run and reports its position in the first stream" do
      shared = noise(200, :theme)

      a = noise(50, :a_head) ++ shared ++ noise(100, :a_tail)
      b = noise(120, :b_head) ++ shared ++ noise(30, :b_tail)

      assert {:ok, %Match{} = match} = Correlator.best_match(a, b, min_frames: 100)

      assert match.start_frame == 50
      assert match.end_frame == 249
      assert match.length == 200
      # a-position 50 aligns with b-position 120, so offset is 50 - 120.
      assert match.offset == -70
    end

    test "returns :no_match when the streams share nothing" do
      a = noise(300, :x)
      b = noise(300, :y)

      assert :no_match = Correlator.best_match(a, b, min_frames: 100)
    end

    test "returns :no_match when the shared run is shorter than min_frames" do
      shared = noise(40, :short_theme)

      a = noise(50, :a2) ++ shared ++ noise(50, :a3)
      b = noise(20, :b2) ++ shared ++ noise(80, :b3)

      assert :no_match = Correlator.best_match(a, b, min_frames: 100)
    end

    test "tolerates small per-frame bit errors within the Hamming threshold" do
      shared = noise(200, :theme)
      # 4 flipped bits is under the tolerance of 6.
      degraded = Enum.map(shared, &perturb(&1, 4))

      a = noise(30, :a4) ++ shared ++ noise(30, :a5)
      b = noise(60, :b4) ++ degraded ++ noise(10, :b5)

      assert {:ok, %Match{} = match} = Correlator.best_match(a, b, min_frames: 100)
      assert match.start_frame == 30
      assert match.length == 200
    end

    test "bridges a short dropout instead of splitting the run" do
      shared = noise(200, :theme)

      # Corrupt 2 consecutive frames beyond recognition in the middle. Gap
      # tolerance is 3, so the run should survive as one.
      corrupted =
        shared
        |> Enum.with_index()
        |> Enum.map(fn
          {_v, i} when i in [100, 101] -> :erlang.phash2({:garbage, i}, 4_294_967_296)
          {v, _i} -> v
        end)

      a = noise(30, :a6) ++ shared ++ noise(30, :a7)
      b = noise(30, :b6) ++ corrupted ++ noise(30, :b7)

      assert {:ok, %Match{} = match} = Correlator.best_match(a, b, min_frames: 150)
      assert match.start_frame == 30
      assert match.length == 200
    end

    test "finds a run that begins at the very start of both streams" do
      shared = noise(150, :cold_open_theme)

      a = shared ++ noise(100, :a8)
      b = shared ++ noise(80, :b8)

      assert {:ok, %Match{} = match} = Correlator.best_match(a, b, min_frames: 100)
      assert match.start_frame == 0
      assert match.length == 150
      assert match.offset == 0
    end

    test "finds a run that ends at the very end of both streams" do
      shared = noise(150, :credits_theme)

      a = noise(100, :a9) ++ shared
      b = noise(40, :b9) ++ shared

      assert {:ok, %Match{} = match} = Correlator.best_match(a, b, min_frames: 100)
      assert match.start_frame == 100
      assert match.end_frame == 249
      assert match.length == 150
    end

    test "prefers the longer run when two candidate offsets both match" do
      short_shared = noise(120, :bumper)
      long_shared = noise(300, :theme)

      a = noise(20, :a10) ++ short_shared ++ noise(20, :a11) ++ long_shared
      b = noise(50, :b10) ++ long_shared ++ noise(50, :b11) ++ short_shared

      assert {:ok, %Match{} = match} = Correlator.best_match(a, b, min_frames: 100)

      # The 300-frame run starts at a-position 20 + 120 + 20 = 160.
      assert match.start_frame == 160
      assert match.length == 300
    end

    test "returns :no_match for empty streams" do
      assert :no_match = Correlator.best_match([], [], min_frames: 10)
      assert :no_match = Correlator.best_match(noise(100, :a12), [], min_frames: 10)
    end
  end
end
