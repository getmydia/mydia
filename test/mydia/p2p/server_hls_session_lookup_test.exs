defmodule Mydia.P2p.ServerHlsSessionLookupTest do
  use ExUnit.Case, async: true

  alias Mydia.P2p.Server

  @registry Mydia.Streaming.HlsSessionRegistry

  test "lookup_hls_session succeeds when user_id matches" do
    session_id = "p2p-test-#{System.unique_integer([:positive])}"
    user_id = System.unique_integer([:positive])
    meta = %{user_id: user_id, temp_dir: "/tmp"}

    {:ok, _} = Registry.register(@registry, {:session, session_id}, meta)

    assert {:ok, pid, info} = Server.lookup_hls_session(session_id, user_id)
    assert pid == self()
    assert info.user_id == user_id
  end

  test "lookup_hls_session returns not_found when user_id does not match" do
    session_id = "p2p-test-#{System.unique_integer([:positive])}"
    owner_id = System.unique_integer([:positive])
    other_user_id = System.unique_integer([:positive])
    meta = %{user_id: owner_id, temp_dir: "/tmp"}

    {:ok, _} = Registry.register(@registry, {:session, session_id}, meta)

    assert {:error, :not_found} = Server.lookup_hls_session(session_id, other_user_id)
  end

  test "lookup_hls_session returns not_found when session does not exist" do
    assert {:error, :not_found} = Server.lookup_hls_session("nonexistent-session", 123)
  end
end
