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

  test "a hand-made mapping survives discovery, and one skip does not abandon the run", %{
    bypass: bypass,
    config: config
  } do
    # alex is deliberately mapped to the account named "sarah", because on this
    # server the account named "alex" is somebody else. Matching by username
    # would repoint alex at that other account, so `only_new: true` leaves every
    # Mydia user who already has a mapping alone. Neither skip is a reason to
    # stop: tonix, who has no mapping at all, is still linked.
    alex = user_fixture(%{username: "alex"})
    user_fixture(%{username: "sarah"})
    tonix = user_fixture(%{username: "tonix"})

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
      |> Plug.Conn.resp(
        200,
        ~s([{"Id":"guid-2","Name":"sarah"},{"Id":"guid-3","Name":"alex"},{"Id":"guid-4","Name":"tonix"}])
      )
    end)

    assert {:ok, %SeedResult{linked: [link], already_mapped: ["sarah", "alex"]}} =
             Users.seed_links(config, only_new: true)

    assert link.user_id == tonix.id
    assert link.remote_user_id == "guid-4"

    kept = Settings.get_media_server_user_link(config.id, alex.id)
    assert kept.id == hand_made.id
    assert kept.remote_user_id == "guid-2"
  end

  test "leaves a paused mapping paused instead of silently resuming it", %{
    bypass: bypass,
    config: config
  } do
    # Pausing is the operator saying "stop syncing this person". Discovery
    # re-links the same account by name on every run, so replacing `enabled` on
    # conflict quietly turned the pause off again and the badge that showed it
    # could never be reached.
    user = user_fixture(%{username: "tonix"})

    {:ok, paused} =
      Settings.upsert_media_server_user_link(%{
        media_server_config_id: config.id,
        user_id: user.id,
        remote_user_id: "jf1",
        remote_username: "tonix",
        enabled: false
      })

    Bypass.expect_once(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([{"Id":"jf1","Name":"tonix"}]))
    end)

    # The loose `%SeedResult{}` this used to match hid which branch ran. A pass
    # that rewrote the row and merely failed to re-enable it would satisfy it
    # just as well as one that left the row alone, so the result is pinned:
    # nothing was linked, and the account is reported as already mapped.
    assert {:ok, %SeedResult{linked: [], already_mapped: ["tonix"]}} =
             Users.seed_links(config, only_new: true)

    assert [kept] = Settings.list_media_server_user_links(config.id)
    assert kept.id == paused.id
    refute kept.enabled
    assert kept.updated_at == paused.updated_at
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
