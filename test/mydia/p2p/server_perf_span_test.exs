defmodule Mydia.P2p.ServerPerfSpanTest do
  @moduledoc """
  Peer requests are timed as `[:mydia, :p2p, :request]` spans, since p2p
  traffic never reaches the HTTP endpoint's telemetry. Drives the handlers with
  `:fake_resource` like `server_request_timeout_test.exs`: the NIF call that
  sends the response fails after the span has already stopped.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Mydia.P2p.Server

  @stop [:mydia, :p2p, :request, :stop]

  @doc false
  def forward(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:span_stop, metadata})
  end

  setup do
    start_supervised!({Task.Supervisor, name: Mydia.P2p.RequestSupervisor})
    start_supervised!({Task.Supervisor, name: Mydia.P2p.StreamSupervisor})

    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler_id, @stop, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "p2p_span/2 returns the function's result inside a span" do
    assert Mydia.Perf.p2p_span("pairing", fn -> :answer end) == :answer
    assert_receive {:span_stop, %{kind: "pairing"}}
  end

  test "a GraphQL request is timed" do
    state = %{resource: :fake_resource, connected_peers: %{}}
    request = %Mydia.P2p.GraphQLRequest{query: "{ __typename }"}

    capture_log(fn ->
      Server.handle_info({:ok, "request_received", "graphql", "req-span", request}, state)
      assert_receive {:span_stop, %{kind: "graphql"}}, 1_000
    end)
  end

  test "a pairing request is timed" do
    state = %{resource: :fake_resource, connected_peers: %{}}
    request = %Mydia.P2p.PairingRequest{device_name: "Span Test Device"}

    capture_log(fn ->
      Server.handle_info({:ok, "request_received", "pairing", "req-pair", request}, state)
      assert_receive {:span_stop, %{kind: "pairing"}}, 1_000
    end)
  end

  test "an HLS request is timed" do
    request = %Mydia.P2p.HlsRequest{session_id: "session-under-test", path: "index.m3u8"}

    capture_log(fn ->
      assert Server.stream_hls_response(:fake_resource, "stream-span", request) == :ok
      assert_receive {:span_stop, %{kind: "hls"}}, 1_000
    end)
  end
end
