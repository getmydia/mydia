defmodule Mydia.Streaming.FfmpegRemuxerActivityTest do
  @moduledoc """
  A remux is one long-lived request, so without a periodic signal the session's
  ten-minute inactivity timeout reaps a viewer who is still watching. The
  throttle matters as much as the callback: firing per 64KB chunk would cast a
  message thousands of times a minute.
  """
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegRemuxer

  describe "throttle_activity/2" do
    test "fires on the first call" do
      {fired?, _last} = FfmpegRemuxer.throttle_activity(nil, 1_000)

      assert fired?
    end

    test "does not fire again inside the interval" do
      {true, last} = FfmpegRemuxer.throttle_activity(nil, 1_000)
      {fired?, ^last} = FfmpegRemuxer.throttle_activity(last, last + 5)

      refute fired?
    end

    test "fires again once the interval has elapsed" do
      {true, last} = FfmpegRemuxer.throttle_activity(nil, 1_000)
      now = last + 30_001
      {fired?, ^now} = FfmpegRemuxer.throttle_activity(last, now)

      assert fired?
    end
  end
end
