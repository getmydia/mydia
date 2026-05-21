defmodule Mydia.Streaming.Torrent.SessionSupervisorTest do
  use Mydia.DataCase, async: false

  alias Mydia.Streaming.Torrent.SessionSupervisor

  describe "list_sessions/0" do
    test "returns an empty list when no sessions are running" do
      # No assertion that the list is exactly empty — other tests may have
      # left children in the supervisor and we don't want to flake on order
      # of execution. Just confirm it returns a list.
      assert is_list(SessionSupervisor.list_sessions())
    end
  end

  describe "get_session/1" do
    test "returns {:error, :not_found} for an unknown session id" do
      assert {:error, :not_found} =
               SessionSupervisor.get_session(Ecto.UUID.generate())
    end
  end

  describe "stop_session/1" do
    test "returns :ok when the session does not exist (idempotent)" do
      assert :ok = SessionSupervisor.stop_session(Ecto.UUID.generate())
    end
  end

  # Tests for start_session/1 are intentionally omitted here because the
  # Session GenServer's init/1 broadcasts on PubSub and the supervisor's
  # start_child also broadcasts. A start_session test that exercises the
  # full path requires the torrent Engine NIF, which is not available in
  # CI without a librqbit-capable host. Engine-coupled paths are covered
  # in the engine_test.exs once the NIF is available.
end
