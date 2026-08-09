defmodule MetadataRelay.PairingCorsTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.Router
  alias MetadataRelay.Pairing

  setup do
    # Ensure ETS table exists for fallback
    Pairing.ensure_ets_table()

    # Clear the ETS table before each test
    if :ets.whereis(:pairing_claims) != :undefined do
      :ets.delete_all_objects(:pairing_claims)
    end

    # Start the rate limiter if not already started
    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    # Clear the rate limiter table before each test
    :ets.delete_all_objects(:rate_limiter)

    :ok
  end

  describe "GET /pairing/claim/:code" do
    test "sends an access-control-allow-origin header so browsers can read it" do
      conn =
        Plug.Test.conn(:get, "/pairing/claim/NOSUCHCODE")
        |> Router.call([])

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") != []
    end
  end

  describe "OPTIONS /pairing/claim/:code" do
    test "answers the preflight" do
      conn =
        Plug.Test.conn(:options, "/pairing/claim/NOSUCHCODE")
        |> Router.call([])

      assert conn.status == 204
      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") != []
    end
  end
end
