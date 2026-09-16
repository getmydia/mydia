defmodule Mydia.P2p.ServerStreamFailureLogTest do
  @moduledoc """
  A player closes its stream on every seek, so a transfer that ends because
  the player stopped reading must not be logged as an error.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.P2p.Server

  # This test changes the global Logger level, so it cannot run concurrently.
  setup do
    original_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  test "a player that stopped reading is not an error" do
    log =
      capture_log(fn ->
        Server.log_stream_failure("peer_stopped: Failed to write chunk data", "file range")
      end)

    refute log =~ "[error]"
    refute log =~ "Failed to stream"
    assert log =~ "[debug]"
    assert log =~ "Player stopped reading the file range"
  end

  test "any other failure is an error" do
    log =
      capture_log(fn ->
        Server.log_stream_failure("Failed to write chunk data: connection lost", "file range")
      end)

    assert log =~ "[error]"
    assert log =~ "Failed to stream file range"
    assert log =~ "connection lost"
  end
end
