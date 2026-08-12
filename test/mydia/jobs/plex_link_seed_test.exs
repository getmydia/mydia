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
      body =
        Jason.encode!(%{
          "users" => [%{"id" => 7, "uuid" => "uuid-7", "username" => user.username}]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    Bypass.stub(bypass, "POST", "/api/v2/home/users/uuid-7/switch", fn conn ->
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

  test "records no_matching_users and enqueues nothing when no profile matches",
       %{bypass: bypass, base: base} do
    config = plex_config()

    # A Plex Home profile whose username matches no Mydia user. Enqueueing a
    # sync here would loop: server mode with no links enqueues this worker.
    Bypass.stub(bypass, "GET", "/api/v2/home/users", fn conn ->
      body =
        Jason.encode!(%{
          "users" => [%{"id" => 9, "uuid" => "uuid-9", "username" => "nobody-here"}]
        })

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
