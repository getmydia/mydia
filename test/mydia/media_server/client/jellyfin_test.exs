defmodule Mydia.MediaServer.Client.JellyfinTest do
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.Client.Jellyfin

  setup do
    bypass = Bypass.open()

    config = %Mydia.Settings.MediaServerConfig{
      name: "Jellyfin",
      type: :jellyfin,
      url: "http://localhost:#{bypass.port}",
      token: "api-key"
    }

    {:ok, bypass: bypass, config: config}
  end

  describe "list_users/1" do
    test "returns id and name for each user", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s([{"Id":"abc123","Name":"tonix"}]))
      end)

      assert {:ok, [%{id: "abc123", name: "tonix"}]} = Jellyfin.list_users(config)
    end
  end

  describe "list_items/2" do
    test "pages until every item is fetched", %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        body =
          case conn.query_params["startIndex"] do
            "0" -> ~s({"Items":[{"Id":"1"},{"Id":"2"}],"TotalRecordCount":3})
            "2" -> ~s({"Items":[{"Id":"3"}],"TotalRecordCount":3})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end)

      assert {:ok, items} = Jellyfin.list_items(config, page_size: 2)
      assert Enum.map(items, & &1["Id"]) == ["1", "2", "3"]
    end

    test "requests user data when a user id is given", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/Items", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["userId"] == "abc123"
        assert conn.query_params["enableUserData"] == "true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"Items":[],"TotalRecordCount":0}))
      end)

      assert {:ok, []} = Jellyfin.list_items(config, user_id: "abc123")
    end
  end

  describe "mark_played/3" do
    test "posts to the current endpoint", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/UserPlayedItems/item1", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["userId"] == "abc123"
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert :ok = Jellyfin.mark_played(config, "abc123", "item1")
    end

    test "falls back to the legacy endpoint on 404", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/UserPlayedItems/item1", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      Bypass.expect_once(bypass, "POST", "/Users/abc123/PlayedItems/item1", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert :ok = Jellyfin.mark_played(config, "abc123", "item1")
    end
  end

  describe "set_position/4" do
    test "converts seconds to ticks", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/UserItems/item1/UserData", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["PlaybackPositionTicks"] == 90_000_000_000
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert :ok = Jellyfin.set_position(config, "abc123", "item1", 9000)
    end

    test "degrades to :ok when the server has no UserData endpoint", %{
      bypass: bypass,
      config: config
    } do
      Bypass.expect_once(bypass, "POST", "/UserItems/item1/UserData", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert :ok = Jellyfin.set_position(config, "abc123", "item1", 9000)
    end
  end
end
