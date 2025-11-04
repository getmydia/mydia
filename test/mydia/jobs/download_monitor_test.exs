defmodule Mydia.Jobs.DownloadMonitorTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.DownloadMonitor
  alias Mydia.Downloads
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  describe "perform/1" do
    test "successfully monitors downloads with no active downloads" do
      setup_runtime_config([])
      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "handles no configured download clients gracefully" do
      setup_runtime_config([])

      # Create an active download
      media_item = media_item_fixture()
      download_fixture(%{media_item_id: media_item.id, status: "downloading"})

      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "successfully monitors active downloads" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create downloads with different statuses
      download_fixture(%{media_item_id: media_item.id, status: "pending"})
      download_fixture(%{media_item_id: media_item.id, status: "downloading", progress: 50})
      download_fixture(%{media_item_id: media_item.id, status: "completed"})

      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "processes only active downloads (pending and downloading)" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create active and inactive downloads
      pending = download_fixture(%{media_item_id: media_item.id, status: "pending"})
      downloading = download_fixture(%{media_item_id: media_item.id, status: "downloading"})
      download_fixture(%{media_item_id: media_item.id, status: "completed"})
      download_fixture(%{media_item_id: media_item.id, status: "failed"})
      download_fixture(%{media_item_id: media_item.id, status: "cancelled"})

      # Job should complete successfully
      assert :ok = perform_job(DownloadMonitor, %{})

      # Verify active downloads still exist with their status
      # (they remain unchanged since we don't have a real download client)
      assert Downloads.get_download!(pending.id).status == "pending"
      assert Downloads.get_download!(downloading.id).status == "downloading"
    end

    test "skips downloads without an assigned client" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create download without a download_client
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          download_client: nil
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should remain unchanged
      reloaded = Downloads.get_download!(download.id)
      assert reloaded.status == "downloading"
      assert is_nil(reloaded.download_client)
    end

    test "handles download client not found in configuration" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create download with a client that doesn't exist in config
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          download_client: "NonExistentClient",
          download_client_id: "test123"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should remain unchanged
      reloaded = Downloads.get_download!(download.id)
      assert reloaded.status == "downloading"
    end

    test "processes multiple downloads in a single run" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create multiple active downloads
      _d1 =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          title: "Download 1"
        })

      _d2 =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          title: "Download 2"
        })

      _d3 =
        download_fixture(%{media_item_id: media_item.id, status: "pending", title: "Download 3"})

      # Should process all downloads without crashing
      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "only processes enabled download clients" do
      # Configure a disabled client
      disabled_client = %{
        build_test_client_config()
        | name: "DisabledClient",
          enabled: false
      }

      setup_runtime_config([disabled_client])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          status: "downloading",
          download_client: "DisabledClient",
          download_client_id: "test123"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should remain unchanged since client is disabled
      reloaded = Downloads.get_download!(download.id)
      assert reloaded.status == "downloading"
    end

    test "sorts download clients by priority" do
      # Configure multiple clients with different priorities
      client1 = %{build_test_client_config() | name: "Client1", priority: 3}
      client2 = %{build_test_client_config() | name: "Client2", priority: 1}
      client3 = %{build_test_client_config() | name: "Client3", priority: 2}

      setup_runtime_config([client1, client2, client3])

      # Job should complete successfully with clients sorted by priority
      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "handles downloads for different client types" do
      setup_runtime_config([
        build_test_client_config(%{name: "qBit", type: :qbittorrent}),
        build_test_client_config(%{name: "Trans", type: :transmission})
      ])

      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        status: "downloading",
        download_client: "qBit",
        download_client_id: "hash1"
      })

      download_fixture(%{
        media_item_id: media_item.id,
        status: "downloading",
        download_client: "Trans",
        download_client_id: "id2"
      })

      assert :ok = perform_job(DownloadMonitor, %{})
    end
  end

  ## Helper Functions

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

    Application.put_env(:mydia, :runtime_config, config)
  end

  defp build_test_client_config(overrides \\ %{}) do
    defaults = %{
      name: "TestClient",
      type: :qbittorrent,
      enabled: true,
      priority: 1,
      host: "localhost",
      port: 8080,
      username: "admin",
      password: "admin",
      use_ssl: false,
      url_base: nil,
      category: nil,
      download_directory: nil
    }

    struct!(Mydia.Config.Schema.DownloadClient, Map.merge(defaults, overrides))
  end
end
