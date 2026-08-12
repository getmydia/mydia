defmodule Mydia.MediaServer.Jellyfin.UsersTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.MediaServer.Jellyfin.Users
  alias Mydia.MediaServer.SeedResult
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

    assert {:ok, %SeedResult{linked: [link], already_mapped: []}} = Users.seed_links(config)
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

    assert {:ok, %SeedResult{linked: [], already_mapped: []}} = Users.seed_links(config)
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

    assert {:ok, %SeedResult{linked: [link]}} = Users.seed_links(config)
    assert is_nil(link.access_token)
  end

  test "leaves an account another Mydia user is already mapped to alone", %{
    bypass: bypass,
    config: config
  } do
    # The operator mapped alex to guid-2 by hand because the names differ. A
    # Jellyfin account happens to be named after another Mydia user, sarah. If
    # discovery wrote sarah -> guid-2 as well, both would import guid-2's watch
    # history, which is the merge per-user mapping exists to prevent.
    alex = user_fixture(%{username: "alex"})
    user_fixture(%{username: "sarah"})

    {:ok, hand_made} =
      Settings.upsert_media_server_user_link(%{
        media_server_config_id: config.id,
        user_id: alex.id,
        remote_user_id: "guid-2",
        remote_username: "sarah",
        enabled: true
      })

    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([{"Id":"guid-2","Name":"sarah"}]))
    end)

    assert {:ok, %SeedResult{linked: [], already_mapped: ["sarah"]}} = Users.seed_links(config)

    assert [kept] = Settings.list_media_server_user_links(config.id)
    assert kept.id == hand_made.id
    assert kept.user_id == alex.id
  end

  test "one claimed account does not abandon the rest of the run", %{
    bypass: bypass,
    config: config
  } do
    alex = user_fixture(%{username: "alex"})
    sarah = user_fixture(%{username: "sarah"})

    {:ok, _hand_made} =
      Settings.upsert_media_server_user_link(%{
        media_server_config_id: config.id,
        user_id: alex.id,
        remote_user_id: "guid-2",
        remote_username: "sarah",
        enabled: true
      })

    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        ~s([{"Id":"guid-2","Name":"sarah"},{"Id":"guid-3","Name":"alex"}])
      )
    end)

    assert {:ok, %SeedResult{linked: [link], already_mapped: ["sarah"]}} =
             Users.seed_links(config)

    assert link.user_id == alex.id
    assert link.remote_user_id == "guid-3"
    refute Enum.any?(Settings.list_media_server_user_links(config.id), &(&1.user_id == sarah.id))
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
