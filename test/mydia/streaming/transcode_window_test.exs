defmodule Mydia.Streaming.TranscodeWindowTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.TranscodeWindow

  # A window running from `first`, having finished everything up to and
  # including `last_ready`, with those same segments on disk.
  defp running(first, last_ready) do
    first
    |> TranscodeWindow.new()
    |> TranscodeWindow.mark_ready(
      if(last_ready < first, do: [], else: Enum.to_list(first..last_ready))
    )
  end

  describe "decide/2 serving" do
    test "serves a segment already on disk" do
      assert TranscodeWindow.decide(running(0, 10), 5) == :serve
    end

    test "serves a segment left behind by an earlier window" do
      # Scrubbing back into a region already watched this session is a plain
      # file read: relocation never clears what is on disk.
      window =
        running(0, 10) |> TranscodeWindow.relocate(100) |> TranscodeWindow.mark_ready([100])

      assert TranscodeWindow.decide(window, 5) == :serve
    end
  end

  describe "decide/2 waiting" do
    test "waits for the segment the encoder is about to finish" do
      assert TranscodeWindow.decide(running(0, 10), 11) == :wait
    end

    test "waits out to the full lookahead budget" do
      assert TranscodeWindow.decide(running(0, 10), 13) == :wait
    end

    test "relocates one segment past the budget" do
      # The budget is the whole reason a small forward skip does not pay for a
      # relocation. One past it is a deliberate jump.
      assert TranscodeWindow.decide(running(0, 10), 14) == {:relocate, 14}
    end

    test "waits for the first segment of a freshly relocated window" do
      window = TranscodeWindow.new(0) |> TranscodeWindow.relocate(100)

      assert TranscodeWindow.decide(window, 100) == :wait
    end
  end

  describe "decide/2 relocating" do
    test "relocates for a segment behind the window that was never produced" do
      # This is the resume-then-scrub-backwards case: nothing before the window
      # start was ever transcoded, so there is nothing to wait for.
      assert TranscodeWindow.decide(running(100, 110), 5) == {:relocate, 5}
    end

    test "relocates for a segment far ahead" do
      assert TranscodeWindow.decide(running(0, 10), 500) == {:relocate, 500}
    end

    test "relocates when no encoder is running" do
      assert TranscodeWindow.decide(TranscodeWindow.stopped(running(0, 10)), 11) ==
               {:relocate, 11}
    end

    test "still serves from disk when no encoder is running" do
      assert TranscodeWindow.decide(TranscodeWindow.stopped(running(0, 10)), 5) == :serve
    end
  end

  describe "relocate/2" do
    test "keeps every segment already on disk" do
      window = running(0, 10) |> TranscodeWindow.relocate(100)

      assert MapSet.member?(window.available, 5)
    end

    test "moves the window and marks nothing ready inside it yet" do
      window = running(0, 10) |> TranscodeWindow.relocate(100)

      assert window.first_index == 100
      assert window.last_ready_index == 99
      assert window.running?
    end
  end

  describe "wait_ahead_segments/0" do
    test "is three" do
      assert TranscodeWindow.wait_ahead_segments() == 3
    end
  end
end
