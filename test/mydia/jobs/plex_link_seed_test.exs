defmodule Mydia.Jobs.PlexLinkSeedTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.Jobs.PlexLinkSeed
  alias Mydia.Settings
  alias Mydia.Sync

  import Mydia.AccountsFixtures

  setup do
    bypass = Bypass.open()
    # plex_tv_base is the /api/v2 root, the same shape as @plex_api_base in Home.
    {:ok, bypass: bypass, base: "http://127.0.0.1:#{bypass.port}/api/v2"}
  end

  defp plex_config(attrs \\ %{}) do
    defaults = %{
      name: "Storage",
      type: :plex,
      url: "http://localhost:32400",
      token: "account-token",
      enabled: true,
      connection_settings: %{"sync_watched" => true}
    }

    {:ok, config} = Settings.create_media_server_config(Map.merge(defaults, attrs))
    config
  end

  test "seeds links from Plex Home and enqueues a server-mode sync",
       %{bypass: bypass, base: base} do
    user = user_fixture()
    config = plex_config()

    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body = Jason.encode!(%{"users" => [%{"id" => 7, "username" => user.username}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    Bypass.stub(bypass, "POST", "/api/v2/home/users/7/switch", fn conn ->
      body = Jason.encode!(%{"authToken" => "per-user-token"})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert [link] = Settings.list_media_server_user_links(config.id)
    assert link.user_id == user.id
    assert link.access_token == "per-user-token"

    assert_enqueued(
      worker: MediaServerWatchedSync,
      args: %{"mode" => "server", "config_id" => config.id}
    )
  end

  test "a hand-made mapping survives a later config save, unchanged",
       %{bypass: bypass, base: base} do
    # This worker is what every Plex config save enqueues, a save that only
    # flips a sync direction included. The operator mapped Mydia user alex to
    # profile 8 by hand, precisely because the profile named "alex" is somebody
    # else in this household. Matching by username would repoint the mapping at
    # profile 7 and file the other person's watch history under alex.
    alex = user_fixture(%{username: "alex"})
    config = plex_config()

    {:ok, hand_made} =
      Settings.upsert_media_server_user_link(%{
        media_server_config_id: config.id,
        user_id: alex.id,
        remote_user_id: "8",
        remote_username: "alex-2",
        access_token: "alex-2-token",
        enabled: true
      })

    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body =
        Jason.encode!(%{
          "users" => [
            %{"id" => 7, "username" => "alex"},
            %{"id" => 8, "username" => "alex-2"}
          ]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    # Stubbed, deliberately, so a seeding pass that decides to repoint alex gets
    # a working token and really does it. Without this the run would fail on the
    # missing endpoint and the assertions below could not tell "left alone" from
    # "tried and could not reach plex.tv". A correct run never calls it.
    Bypass.stub(bypass, "POST", "/api/v2/home/users/7/switch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "other-alex-token"}))
    end)

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert [kept] = Settings.list_media_server_user_links(config.id)
    assert kept.id == hand_made.id
    assert kept.remote_user_id == "8"
    assert kept.remote_username == "alex-2"
    assert kept.access_token == "alex-2-token"
    assert kept.updated_at == hand_made.updated_at

    assert Sync.last_run("plex", config.id).skip_reason == "no_matching_users"
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "still picks up a Plex Home profile that has no mapping yet",
       %{bypass: bypass, base: base} do
    # The other half of the guard above. Leaving existing mappings alone must
    # not stop a household member who joined since the last pass from being
    # linked, which is the whole reason this runs on every save.
    alex = user_fixture(%{username: "alex"})
    kid = user_fixture(%{username: "kid"})
    config = plex_config()

    {:ok, hand_made} =
      Settings.upsert_media_server_user_link(%{
        media_server_config_id: config.id,
        user_id: alex.id,
        remote_user_id: "8",
        remote_username: "alex-2",
        access_token: "alex-2-token",
        enabled: true
      })

    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body =
        Jason.encode!(%{
          "users" => [
            %{"id" => 7, "username" => "alex"},
            %{"id" => 9, "username" => "kid"}
          ]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    Bypass.stub(bypass, "POST", "/api/v2/home/users/9/switch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "kid-token"}))
    end)

    # Same reason as above: a pass that decides to repoint alex must be able to.
    Bypass.stub(bypass, "POST", "/api/v2/home/users/7/switch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "other-alex-token"}))
    end)

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert %{remote_user_id: "8", access_token: "alex-2-token"} =
             Settings.get_media_server_user_link(config.id, alex.id)

    assert %{remote_user_id: "9", access_token: "kid-token"} =
             Settings.get_media_server_user_link(config.id, kid.id)

    assert Settings.get_media_server_user_link(config.id, alex.id).id == hand_made.id
  end

  test "records owner_link_ambiguous and writes nothing when two admins could own the token",
       %{bypass: bypass, base: base} do
    # config.token belongs to whoever ran OAuth. With more than one admin,
    # picking the first by query order would bind admin A's Mydia account to
    # admin B's Plex watch state.
    admin_user_fixture(%{username: "first-admin"})
    admin_user_fixture(%{username: "second-admin"})
    config = plex_config()

    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert [] = Settings.list_media_server_user_links(config.id)
    assert Sync.last_run("plex", config.id).skip_reason == "owner_link_ambiguous"
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "a scheduler tick does not put back the mappings an operator deleted",
       %{bypass: bypass, base: base} do
    # Deleting a mapping promises watched sync will skip that user until it is
    # mapped again. The scheduler seeds a Plex server that has no links, so once
    # the last mapping was gone the next tick recreated the lot.
    user = user_fixture()
    config = plex_config()

    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body = Jason.encode!(%{"users" => [%{"id" => 7, "username" => user.username}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    Bypass.stub(bypass, "POST", "/api/v2/home/users/7/switch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"authToken" => "per-user-token"}))
    end)

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert [link] = Settings.list_media_server_user_links(config.id)
    {:ok, _deleted} = Settings.delete_media_server_user_link(link)

    assert :ok =
             perform_job(MediaServerWatchedSync, %{"mode" => "server", "config_id" => config.id})

    assert [] = Settings.list_media_server_user_links(config.id)
    assert Sync.last_run("plex", config.id).skip_reason == "no_user_mapping"
    assert [] = all_enqueued(worker: PlexLinkSeed)
  end

  test "records no_matching_users and enqueues nothing when no profile matches",
       %{bypass: bypass, base: base} do
    config = plex_config()

    # A Plex Home profile whose username matches no Mydia user. Enqueueing a
    # sync here would loop: server mode with no links enqueues this worker.
    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body = Jason.encode!(%{"users" => [%{"id" => 9, "username" => "nobody-here"}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert [] = Settings.list_media_server_user_links(config.id)
    assert Sync.last_run("plex", config.id).skip_reason == "no_matching_users"
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "records link_seeding_failed and returns an error when plex.tv rejects the token",
       %{bypass: bypass, base: base} do
    config = plex_config()

    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    assert {:error, _reason} =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert Sync.last_run("plex", config.id).skip_reason == "link_seeding_failed"
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "does nothing when watched sync is disabled", %{base: base} do
    # maybe_seed_plex_links/1 fires on every Plex config save, including one
    # where the operator only wants library refresh and never opted into
    # watched-status sync. Seeding here would enumerate Plex Home and mint a
    # long-lived per-profile token for every household member for a feature
    # they never asked for.
    config = plex_config(%{connection_settings: %{"sync_watched" => false}})

    assert :ok =
             perform_job(PlexLinkSeed, %{
               "config_id" => config.id,
               "plex_tv_base" => base
             })

    assert [] = Settings.list_media_server_user_links(config.id)
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "is a no-op for a Jellyfin config" do
    {:ok, config} =
      Settings.create_media_server_config(%{
        name: "Jelly",
        type: :jellyfin,
        url: "http://localhost:8096",
        token: "tok",
        enabled: true
      })

    assert :ok = perform_job(PlexLinkSeed, %{"config_id" => config.id})
    assert [] = Settings.list_media_server_user_links(config.id)
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "is a no-op when the config was deleted between enqueue and execution" do
    config = plex_config()
    {:ok, _} = Settings.delete_media_server_config(config)

    assert :ok = perform_job(PlexLinkSeed, %{"config_id" => config.id})
  end
end
