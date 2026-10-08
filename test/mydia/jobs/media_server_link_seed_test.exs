defmodule Mydia.Jobs.MediaServerLinkSeedTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.Jobs.MediaServerLinkSeed
  alias Mydia.Settings
  alias Mydia.Sync

  import Mydia.AccountsFixtures

  defp jellyfin_config(attrs \\ %{}) do
    defaults = %{
      name: "Jelly",
      type: :jellyfin,
      url: "http://localhost:8096",
      token: "api-key",
      enabled: true,
      connection_settings: %{"sync_watched" => true}
    }

    {:ok, config} = Settings.create_media_server_config(Map.merge(defaults, attrs))
    config
  end

  test "does nothing when watched sync is disabled" do
    # The seed is enqueued on every config save, including one where the
    # operator only wants library refresh and never opted into watched-status
    # sync. Seeding here would enumerate the server's accounts for a feature they
    # never asked for.
    config = jellyfin_config(%{connection_settings: %{"sync_watched" => false}})

    assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

    assert [] = Settings.list_media_server_user_links(config.id)
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "is a no-op for a Jellyfin config that never enabled watched sync" do
    {:ok, config} =
      Settings.create_media_server_config(%{
        name: "Jelly",
        type: :jellyfin,
        url: "http://localhost:8096",
        token: "tok",
        enabled: true
      })

    assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})
    assert [] = Settings.list_media_server_user_links(config.id)
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "never seeds an env-configured server, which cannot own link rows" do
    original = Application.get_env(:mydia, :runtime_config)
    on_exit(fn -> Application.put_env(:mydia, :runtime_config, original) end)

    Application.put_env(:mydia, :runtime_config, %{
      Mydia.Config.Schema.defaults()
      | media_servers: [
          %{
            name: "from-env",
            type: :jellyfin,
            enabled: true,
            url: "http://127.0.0.1:9",
            token: "tok",
            connection_settings: %{"sync_watched" => "true"}
          }
        ]
    })

    id = "runtime::media_server::from-env"
    assert Settings.runtime_config?(Settings.get_media_server_config!(id))

    assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => id})
    assert [] = Settings.list_media_server_user_links(id)
    assert [] = all_enqueued(worker: MediaServerWatchedSync)
  end

  test "is a no-op when the config was deleted between enqueue and execution" do
    config = jellyfin_config()
    {:ok, _} = Settings.delete_media_server_config(config)

    assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})
  end

  describe "seeding against a Jellyfin server" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, url: "http://127.0.0.1:#{bypass.port}"}
    end

    defp stub_users(bypass, users) do
      Bypass.stub(bypass, "GET", "/Users", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(users))
      end)
    end

    test "seeds links, stamps the config and enqueues a server-mode sync",
         %{bypass: bypass, url: url} do
      user = user_fixture()
      config = jellyfin_config(%{url: url})
      stub_users(bypass, [%{"Id" => "guid-7", "Name" => user.username}])

      assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

      assert [link] = Settings.list_media_server_user_links(config.id)
      assert link.user_id == user.id
      assert link.remote_user_id == "guid-7"
      assert is_nil(link.access_token)

      assert MediaServerLinkSeed.seeded_before?(Settings.get_media_server_config!(config.id))

      assert_enqueued(
        worker: MediaServerWatchedSync,
        args: %{"mode" => "server", "config_id" => config.id}
      )
    end

    test "a hand-made mapping survives a later save, unchanged", %{bypass: bypass, url: url} do
      alex = user_fixture(%{username: "alex"})
      config = jellyfin_config(%{url: url})

      {:ok, hand_made} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: alex.id,
          remote_user_id: "guid-8",
          remote_username: "alex-2",
          enabled: true
        })

      stub_users(bypass, [
        %{"Id" => "guid-7", "Name" => "alex"},
        %{"Id" => "guid-8", "Name" => "alex-2"}
      ])

      assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

      assert [kept] = Settings.list_media_server_user_links(config.id)
      assert kept.id == hand_made.id
      assert kept.remote_user_id == "guid-8"
      assert kept.updated_at == hand_made.updated_at

      assert Sync.last_run("jellyfin", config.id).skip_reason == "no_matching_users"
      assert [] = all_enqueued(worker: MediaServerWatchedSync)
    end

    test "still picks up an account that has no mapping yet", %{bypass: bypass, url: url} do
      alex = user_fixture(%{username: "alex"})
      sam = user_fixture(%{username: "sam"})
      config = jellyfin_config(%{url: url})

      {:ok, _} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: alex.id,
          remote_user_id: "guid-8",
          remote_username: "alex-2",
          enabled: true
        })

      stub_users(bypass, [
        %{"Id" => "guid-8", "Name" => "alex-2"},
        %{"Id" => "guid-9", "Name" => "sam"}
      ])

      assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

      links = Settings.list_media_server_user_links(config.id)
      assert length(links) == 2
      assert Enum.find(links, &(&1.user_id == sam.id)).remote_user_id == "guid-9"
    end

    test "a scheduler tick does not put back the mappings an operator deleted",
         %{bypass: bypass, url: url} do
      user = user_fixture()
      config = jellyfin_config(%{url: url})
      stub_users(bypass, [%{"Id" => "guid-7", "Name" => user.username}])

      assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

      assert [link] = Settings.list_media_server_user_links(config.id)
      {:ok, _deleted} = Settings.delete_media_server_user_link(link)

      assert :ok =
               perform_job(MediaServerWatchedSync, %{"mode" => "server", "config_id" => config.id})

      assert [] = Settings.list_media_server_user_links(config.id)
      assert Sync.last_run("jellyfin", config.id).skip_reason == "no_user_mapping"
      assert [] = all_enqueued(worker: MediaServerLinkSeed)
    end

    test "records no_matching_users and enqueues nothing when no account matches",
         %{bypass: bypass, url: url} do
      config = jellyfin_config(%{url: url})
      stub_users(bypass, [%{"Id" => "guid-9", "Name" => "nobody-here"}])

      assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

      assert [] = Settings.list_media_server_user_links(config.id)
      assert Sync.last_run("jellyfin", config.id).skip_reason == "no_matching_users"
      assert [] = all_enqueued(worker: MediaServerWatchedSync)
      # A conclusive pass is stamped even when it linked nothing.
      assert MediaServerLinkSeed.seeded_before?(Settings.get_media_server_config!(config.id))
    end

    test "records link_seeding_failed, errors and does not stamp when the token is rejected",
         %{bypass: bypass, url: url} do
      config = jellyfin_config(%{url: url})

      Bypass.stub(bypass, "GET", "/Users", fn conn -> Plug.Conn.resp(conn, 401, "") end)

      assert {:error, _reason} = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})

      assert Sync.last_run("jellyfin", config.id).skip_reason == "link_seeding_failed"
      assert [] = all_enqueued(worker: MediaServerWatchedSync)
      refute MediaServerLinkSeed.seeded_before?(Settings.get_media_server_config!(config.id))
    end
  end
end
