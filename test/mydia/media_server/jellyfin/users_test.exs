defmodule Mydia.MediaServer.Jellyfin.UsersTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.MediaServer.Jellyfin.Users
  alias Mydia.Settings

  setup do
    bypass = Bypass.open()

    {:ok, config} =
      Settings.create_media_server_config(%{
        name: "Jellyfin",
        type: :jellyfin,
        url: "http://localhost:#{bypass.port}",
        token: "api-key",
        enabled: true,
        connection_settings: %{}
      })

    {:ok, bypass: bypass, config: config}
  end

  test "links Jellyfin accounts to Mydia users by username, case-insensitively", %{
    bypass: bypass,
    config: config
  } do
    user = user_fixture(%{username: "tonix"})

    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s([{"Id":"jf1","Name":"Tonix"},{"Id":"jf2","Name":"nobody"}])
      )
    end)

    assert {:ok, [link]} = Users.seed_links(config)
    assert link.user_id == user.id
    assert link.remote_user_id == "jf1"
    assert link.remote_username == "Tonix"
    assert link.access_token == nil
  end

  test "skips a Jellyfin account that matches no Mydia user", %{
    bypass: bypass,
    config: config
  } do
    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([{"Id":"jf1","Name":"nobody"}]))
    end)

    assert {:ok, []} = Users.seed_links(config)
    assert Settings.list_media_server_user_links(config.id) == []
  end

  test "does not create a link that carries an access token", %{
    bypass: bypass,
    config: config
  } do
    user_fixture(%{username: "tonix"})

    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([{"Id":"jf1","Name":"Tonix"}]))
    end)

    assert {:ok, [link]} = Users.seed_links(config)
    assert is_nil(link.access_token)
  end

  test "propagates an error from list_users and creates no links", %{
    bypass: bypass,
    config: config
  } do
    user_fixture(%{username: "tonix"})

    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    assert {:error, _reason} = Users.seed_links(config)
    assert Settings.list_media_server_user_links(config.id) == []
  end
end
