defmodule Mydia.P2p.ServerRequestTimeoutTest do
  @moduledoc """
  Peer requests run under a bounded `Task.Supervisor`, and a bound is only
  worth having if its slots come back.

  Nothing else reclaims one. A handler blocked on an unresponsive filesystem
  returns on its own schedule or never, and the Rust core's `RESPONSE_TIMEOUT`
  only abandons the peer's side of the exchange; it cannot reach into the BEAM
  and stop the task. Without the deadline these cover, enough hung requests
  would occupy every slot permanently and the host would answer nothing but
  "Server busy" from then on.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.P2p.Server

  setup do
    # The real one is started only when remote access is enabled, which it is
    # not in test.
    start_supervised!({Task.Supervisor, name: Mydia.P2p.RequestSupervisor})
    :ok
  end

  defp children, do: Task.Supervisor.children(Mydia.P2p.RequestSupervisor)

  test "a handler that hangs is killed and its slot returned" do
    log =
      capture_log(fn ->
        # `:fake_resource` is never reached: sending the response needs the
        # NIF, and this request times out before it gets that far.
        Server.serve_request(
          :fake_resource,
          "req-hang",
          "hang test",
          fn -> Process.sleep(:infinity) end,
          100
        )

        assert_slots_reclaimed()
      end)

    assert log =~ "timed out"
    assert log =~ "was killed"
  end

  test "a handler that returns promptly does not wait out the deadline" do
    # A generous deadline the handler must not be blocked on: if the
    # implementation waited for it rather than for the handler, this would take
    # a minute instead of milliseconds.
    Server.serve_request(
      :fake_resource,
      "req-fast",
      "fast test",
      fn -> {:error, "done"} end,
      60_000
    )

    assert_slots_reclaimed()
  end

  # Polls rather than sleeping a fixed span: the slot comes back once the task
  # exits, which is promptly but not synchronously.
  defp assert_slots_reclaimed(attempts \\ 100) do
    slots = children()

    cond do
      slots == [] ->
        assert slots == []

      attempts > 0 ->
        Process.sleep(50)
        assert_slots_reclaimed(attempts - 1)

      true ->
        flunk("the supervisor still holds #{length(slots)} children after the request is over")
    end
  end
end
