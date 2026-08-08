defmodule MetadataRelay.PairingCorsTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias MetadataRelay.Router

  @opts Router.init([])

  describe "GET /pairing/claim/:code" do
    test "sends an access-control-allow-origin header so browsers can read it" do
      conn =
        :get
        |> conn("/pairing/claim/NOSUCHCODE")
        |> Router.call(@opts)

      assert get_resp_header(conn, "access-control-allow-origin") != []
    end
  end

  describe "OPTIONS /pairing/claim/:code" do
    test "answers the preflight" do
      conn =
        :options
        |> conn("/pairing/claim/NOSUCHCODE")
        |> Router.call(@opts)

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") != []
    end
  end
end
