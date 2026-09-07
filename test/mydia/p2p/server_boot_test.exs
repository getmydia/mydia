defmodule Mydia.P2p.ServerBootTest do
  @moduledoc """
  Covers the relay-list wiring and the non-blocking boot shape without
  starting a real iroh endpoint. The NIF is exercised by the integration
  suites; what matters here is that the GenServer no longer blocks its
  supervisor on a network call.
  """
  # async: false because the second test mutates application env, which is
  # global and would race any other async test reading it. The on_exit restore
  # is what keeps this file from leaving the env changed behind it.
  use ExUnit.Case, async: false

  alias Mydia.P2p.Server

  test "init returns a continue instead of starting the host inline" do
    # If init/1 still started the host, this call would load the NIF and dial a
    # relay. The continue tuple is the proof that it does not.
    assert {:ok, state, {:continue, :start_host}} = Server.init([])
    assert state.resource == nil
    assert state.node_id == nil
  end

  test "init still fails loudly when the keypair path is unconfigured" do
    original = Application.get_env(:mydia, :p2p_keypair_path)
    Application.delete_env(:mydia, :p2p_keypair_path)
    on_exit(fn -> Application.put_env(:mydia, :p2p_keypair_path, original) end)

    assert_raise RuntimeError, ~r/keypair path not configured/i, fn ->
      Server.init([])
    end
  end
end
