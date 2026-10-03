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

  describe "stream_to_conn/4 with a halting on_activity" do
    # A stand-in for FFmpeg: emits one chunk, then would run for a minute.
    defp open_slow_port do
      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          :use_stdio,
          args: ["-c", "echo chunk; sleep 60"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {port, os_pid}
    end

    test "returns promptly and sends nothing when on_activity returns :halt" do
      {port, os_pid} = open_slow_port()
      conn = Plug.Test.conn(:get, "/stream")

      {micros, conn} =
        :timer.tc(fn ->
          FfmpegRemuxer.stream_to_conn(conn, port, os_pid, on_activity: fn -> :halt end)
        end)

      assert micros < 5_000_000
      assert Port.info(port) == nil
      refute conn.resp_body =~ "chunk"
    end

    test "keeps streaming when on_activity returns anything else" do
      {port, os_pid} = open_slow_port()
      test_pid = self()
      conn = Plug.Test.conn(:get, "/stream")

      # Halt on the second heartbeat is not reachable (throttled), so end the
      # stream by killing the process once the first chunk has been sent.
      on_activity = fn ->
        send(test_pid, :activity)
        spawn(fn -> System.cmd("kill", [to_string(os_pid)]) end)
        :ok
      end

      conn = FfmpegRemuxer.stream_to_conn(conn, port, os_pid, on_activity: on_activity)

      assert_received :activity
      assert conn.resp_body =~ "chunk"
    end
  end
end
