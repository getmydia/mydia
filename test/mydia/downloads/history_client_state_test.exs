defmodule Mydia.Downloads.HistoryClientStateTest do
  @moduledoc """
  Covers the classification that `DownloadMonitor` acts on: a client that is
  present, one that is merely disabled, and one that is gone. Also covers the
  read path reporting an adoption candidate without writing anything.

  No client here is reachable over the network, so every configured client
  resolves to `:unreachable`. That is deliberate: it isolates the config-state
  classification from live torrent data.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Downloads

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  describe "list_downloads_with_status/1 client config state" do
    test "marks a download whose client was removed" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "gone",
        download_client_id: "hash-a"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :removed
      assert enriched.adoptable_client == nil
    end

    test "marks a download whose client is disabled, not removed" do
      setup_runtime_config([client_config(%{name: "paused", enabled: false})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "paused",
        download_client_id: "hash-b"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :disabled
    end

    test "leaves client_config_state nil for a download with no client assigned" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: nil,
        download_client_id: nil
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == nil
    end

    test "reports :present for a configured, enabled client" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "kept",
        download_client_id: "hash-c"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :present
    end

    test "marks a download as :removed when no clients are configured at all" do
      # The single-client operator's shape: deleting your only client leaves
      # `all_configured == []`, an early-return branch that used to leave
      # `client_config_state` nil unconditionally. A download that still
      # names a client must classify :removed here too, not just when a
      # mismatched client is present in a non-empty list.
      setup_runtime_config([])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "gone",
        download_client_id: "hash-e"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :removed
    end

    test "leaves client_config_state nil with no clients configured and no client assigned" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: nil,
        download_client_id: nil
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == nil
    end

    test "does not write the adoption candidate to the database" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "gone",
          download_client_id: "hash-d"
        })

      _ = Downloads.list_downloads_with_status(filter: :all)

      # The read path reports; it never persists. DownloadMonitor is the only
      # writer.
      assert Downloads.get_download!(download.id).download_client == "gone"
    end
  end

  defp client_config(overrides) do
    Enum.into(overrides, %{
      name: "TestClient",
      type: :qbittorrent,
      enabled: true,
      host: "localhost",
      port: 8080,
      use_ssl: false,
      username: "admin",
      password: "admin",
      priority: 1
    })
  end

  defp setup_runtime_config(download_clients) do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: download_clients
    }

    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end
end
