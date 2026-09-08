defmodule Mydia.P2p.ServerStreamBoundTest do
  @moduledoc """
  HLS byte-serving runs under a bounded `Task.Supervisor`, separate from the one
  serving GraphQL requests.

  iroh accepts an inbound connection on ALPN alone, so a peer needs no
  credential to make the host spawn one of these, and a request against a
  session still warming up parks its task for the whole readiness budget plus a
  waiter inside the session. That budget is two minutes, so an unbounded spawn
  here is a denial-of-service hole that scales with how patient the host is
  willing to be with a cold encoder.

  These assert on whether the handler *ran*, not on log wording alone: a full
  bound must refuse without starting one, and an available slot must actually
  start one. The execution signal is `handle_hls_stream/3` rejecting the
  unauthenticated fixture request, which only something inside the spawned
  handler can emit.

  Asserting the peer-visible 503 instead would need a seam over the P2P NIF,
  and there is none: `Mydia.P2p.send_hls_header/3` is a bare
  `:erlang.nif_error` stub with no behaviour or mock behind it. The sibling
  `server_request_timeout_test.exs` drives `:fake_resource` the same way for
  the same reason.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.P2p.Server

  setup do
    # The real one starts only when remote access is enabled, which it is not in
    # test. max_children: 1 so a single occupant fills it.
    start_supervised!({Task.Supervisor, name: Mydia.P2p.StreamSupervisor, max_children: 1})
    :ok
  end

  defp request do
    %Mydia.P2p.HlsRequest{session_id: "session-under-test", path: "index.m3u8"}
  end

  defp children, do: Task.Supervisor.children(Mydia.P2p.StreamSupervisor)

  # The handler runs concurrently, so its log lands after the call returns.
  # Polls rather than sleeping a fixed span.
  defp wait_until_settled(remaining, attempts \\ 400) do
    cond do
      length(children()) <= remaining -> :ok
      attempts == 0 -> flunk("handler task never finished")
      true -> Process.sleep(5) && wait_until_settled(remaining, attempts - 1)
    end
  end

  test "starts a handler while the bound has room" do
    log =
      capture_log(fn ->
        # `:fake_resource` never reaches the NIF: send_hls_error/4 rescues the
        # ArgumentError a fake resource raises, which is the same guard that
        # covers a peer disconnecting mid-response.
        assert Server.stream_hls_response(:fake_resource, "stream-with-room", request()) == :ok
        wait_until_settled(0)
      end)

    # The handler body ran. Without this the test would pass on an
    # implementation that silently started nothing.
    assert log =~ "HLS auth failed"
    refute log =~ "too many streams in flight"
  end

  test "refuses without starting a handler once the bound is full" do
    # Occupy the only slot. This stands in for a peer's request parked in
    # await_ready/2 waiting on an encoder that has not written a playlist yet.
    {:ok, occupant} =
      Task.Supervisor.start_child(Mydia.P2p.StreamSupervisor, fn -> Process.sleep(:infinity) end)

    log =
      capture_log(fn ->
        assert Server.stream_hls_response(:fake_resource, "stream-when-full", request()) == :ok
      end)

    assert log =~ "too many streams in flight"

    # The point of the bound: no second handler was started. `start_child`
    # refuses synchronously, so there is no race with a task still spawning.
    refute log =~ "HLS auth failed"
    assert children() == [occupant]
  end
end
