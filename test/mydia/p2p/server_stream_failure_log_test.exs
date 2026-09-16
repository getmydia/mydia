defmodule Mydia.P2p.ServerStreamFailureLogTest do
  @moduledoc """
  A player closes its stream on every seek, so a transfer that ends because
  the player stopped reading must not be logged as an error.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.P2p.Server

  test "a player that stopped reading is not an error" do
    log =
      capture_log(fn ->
        Server.log_stream_failure("peer_stopped: Failed to write chunk data", "file range")
      end)

    refute log =~ "[error]"
    refute log =~ "Failed to stream"
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
