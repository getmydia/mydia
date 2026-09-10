defmodule Mydia.Streaming.HlsSessionSeekAlignmentTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HlsSession
  alias Mydia.Streaming.SegmentPlan

  describe "encoder_start_position/3" do
    setup do
      {:ok, plan} = SegmentPlan.build(3600.0)
      %{plan: plan}
    end

    test "a :full session's first encoder starts on the segment grid", %{plan: plan} do
      first_index = SegmentPlan.index_for_time(plan, 1234)

      assert first_index == 308
      assert HlsSession.encoder_start_position(plan, first_index, 1234) == 1232
    end

    test "agrees with where a relocation to the same segment starts", %{plan: plan} do
      # relocate/2 starts at trunc(SegmentPlan.start_time(plan, target)). If the
      # first encoder disagreed, its segment 308 and a relocated one would
      # begin at different times.
      assert HlsSession.encoder_start_position(plan, 308, 1234) ==
               trunc(SegmentPlan.start_time(plan, 308))
    end

    test "a resume already on the grid starts where it was asked to", %{plan: plan} do
      assert HlsSession.encoder_start_position(plan, 7, 28) == 28
    end

    test "a :window session starts where it was asked to" do
      assert HlsSession.encoder_start_position(nil, 0, 1234) == 1234
    end
  end
end
