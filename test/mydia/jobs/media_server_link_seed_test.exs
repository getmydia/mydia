defmodule Mydia.Jobs.MediaServerLinkSeedTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.Jobs.MediaServerLinkSeed
  alias Mydia.Settings

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

  test "is a no-op when the config was deleted between enqueue and execution" do
    config = jellyfin_config()
    {:ok, _} = Settings.delete_media_server_config(config)

    assert :ok = perform_job(MediaServerLinkSeed, %{"config_id" => config.id})
  end
end
