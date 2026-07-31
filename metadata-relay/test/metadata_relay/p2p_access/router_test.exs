defmodule MetadataRelay.P2pAccess.RouterTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.P2pAccess
  alias MetadataRelay.P2pAccess.Store
  alias MetadataRelay.Router

  @bearer "test-relay-bearer"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})

    Store.init_tables()
    :ets.delete_all_objects(:p2p_sightings)
    :ets.delete_all_objects(:p2p_blocked)
    MetadataRelay.Repo.delete_all(MetadataRelay.P2pAccess.Block)

    original = Application.get_env(:metadata_relay, :p2p_access_bearer_tokens)
    Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, [@bearer])
    on_exit(fn -> Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, original) end)

    :ok
  end

  defp endpoint_id(n),
    do: String.pad_leading(Integer.to_string(n, 16), 64, "0") |> String.downcase()

  defp request(opts) do
    conn = Plug.Test.conn(:post, "/p2p/access", "")

    conn =
      case Keyword.get(opts, :bearer, @bearer) do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    conn =
      case Keyword.get(opts, :endpoint_id, endpoint_id(1)) do
        nil -> conn
        id -> Plug.Conn.put_req_header(conn, "x-iroh-endpoint-id", id)
      end

    Router.call(conn, [])
  end

  test "allows an unknown endpoint with the literal body true" do
    conn = request([])

    assert conn.status == 200
    assert conn.resp_body == "true"
  end

  test "responds as text/plain, not JSON" do
    conn = request([])

    assert ["text/plain" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
  end

  test "denies when the bearer is missing" do
    conn = request(bearer: nil)

    assert conn.status == 403
    refute conn.resp_body == "true"
  end

  test "denies when the bearer is wrong" do
    conn = request(bearer: "wrong-token")

    assert conn.status == 403
    refute conn.resp_body == "true"
  end

  test "accepts any bearer from a rotation list" do
    Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, ["old", "new"])

    assert request(bearer: "old").status == 200
    assert request(bearer: "new").status == 200
  end

  test "denies a blocked endpoint" do
    id = endpoint_id(2)
    :ok = P2pAccess.block(id, "bandwidth abuse")

    conn = request(endpoint_id: id)

    assert conn.status == 403
    refute conn.resp_body == "true"
  end

  test "rejects a missing endpoint id header" do
    conn = request(endpoint_id: nil)

    assert conn.status == 400
    refute conn.resp_body == "true"
  end

  test "rejects a malformed endpoint id" do
    conn = request(endpoint_id: "not-a-valid-endpoint-id")

    assert conn.status == 400
    refute conn.resp_body == "true"
  end

  test "accepts an uppercase endpoint id and records it downcased" do
    upper = String.duplicate("AB", 32)

    assert request(endpoint_id: upper).status == 200
    assert {:ok, _} = Store.lookup_sighting(String.duplicate("ab", 32))
  end

  test "increments the sighting count across repeated calls" do
    id = endpoint_id(3)

    request(endpoint_id: id)
    request(endpoint_id: id)

    assert {:ok, {_first, _last, 2}} = Store.lookup_sighting(id)
  end

  test "does not record a sighting when the bearer is rejected" do
    id = endpoint_id(4)

    request(bearer: "wrong-token", endpoint_id: id)

    assert Store.lookup_sighting(id) == :error
  end
end
