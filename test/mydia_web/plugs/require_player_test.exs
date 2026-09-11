defmodule MydiaWeb.Plugs.RequirePlayerTest do
  use MydiaWeb.ConnCase, async: false

  alias MydiaWeb.Plugs.RequirePlayer

  describe "call/2" do
    test "passes everything through while the player is on" do
      conn = Plug.Test.conn(:get, "/api/graphql")
      refute RequirePlayer.call(conn, RequirePlayer.init([])).halted
    end

    test "refuses API requests with a GraphQL-shaped body when the player is off" do
      disable_player()

      conn = RequirePlayer.call(Plug.Test.conn(:post, "/api/graphql"), RequirePlayer.init([]))

      assert conn.halted
      assert conn.status == 404

      assert %{"errors" => [%{"extensions" => %{"code" => "PLAYER_DISABLED"}}]} =
               Jason.decode!(conn.resp_body)
    end

    test "with :only, touches nothing outside its prefix" do
      disable_player()
      opts = RequirePlayer.init(only: "/player")

      assert RequirePlayer.call(Plug.Test.conn(:get, "/player/main.dart.js"), opts).halted
      refute RequirePlayer.call(Plug.Test.conn(:get, "/players"), opts).halted
      refute RequirePlayer.call(Plug.Test.conn(:get, "/movies"), opts).halted
    end
  end

  describe "through the endpoint, with the player off" do
    setup do
      disable_player()
    end

    test "GraphQL answers 404 with PLAYER_DISABLED", %{conn: conn} do
      conn = post(conn, "/api/graphql", %{query: "{ __typename }"})

      assert %{"errors" => [%{"extensions" => %{"code" => "PLAYER_DISABLED"}}]} =
               json_response(conn, 404)
    end

    test "a streaming route answers 404 before authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/stream/file/00000000-0000-0000-0000-000000000000")
      assert json_response(conn, 404)["errors"]
    end

    test "the web player bundle is not served", %{conn: conn} do
      conn = get(conn, "/player/index.html")
      assert conn.status == 404
    end

    test "the general API is untouched", %{conn: conn} do
      conn = get(conn, "/api/v1/indexers")
      refute conn.status == 404
    end
  end

  describe "through the endpoint, with the player on" do
    test "GraphQL answers", %{conn: conn} do
      conn = post(conn, "/api/graphql", %{query: "{ __typename }"})
      refute conn.status == 404
    end
  end
end
