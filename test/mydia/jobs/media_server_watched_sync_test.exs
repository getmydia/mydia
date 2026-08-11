defmodule Mydia.Jobs.MediaServerWatchedSyncTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.Settings
  alias Mydia.Sync

  import Mydia.AccountsFixtures

  describe "perform/1 with mode all_enabled" do
    test "skips when no servers have watched sync enabled" do
      {:ok, _server} =
        Settings.create_media_server_config(%{
          name: "Test Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "test-token",
          enabled: true,
          connection_settings: %{}
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})
    end

    test "enqueues individual jobs for enabled servers with sync_watched" do
      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "Sync Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "test-token",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert_enqueued(
        worker: MediaServerWatchedSync,
        args: %{"config_id" => server.id, "user_id" => user.id}
      )
    end
  end

  describe "perform/1 with individual config" do
    test "skips when server is disabled" do
      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "Disabled Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "test-token",
          enabled: false,
          connection_settings: %{"sync_watched" => true}
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => server.id,
                 "user_id" => user.id
               })
    end

    test "skips when sync_watched is not enabled" do
      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "No Sync Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "test-token",
          enabled: true,
          connection_settings: %{}
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => server.id,
                 "user_id" => user.id
               })
    end
  end

  describe "skip visibility" do
    test "an individual job whose config was disabled after enqueue records a skip" do
      # A job can be enqueued and then have its config disabled before it runs.
      # That path used to return {:ok, :skipped} with no trace, which is the
      # same silence this change exists to remove.
      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: false,
          connection_settings: %{"sync_watched" => "true"}
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id
               })

      run = Sync.last_run("plex", config.id)
      assert run.status == :skipped
      assert run.skip_reason == "server_disabled"
      assert run.user_id == user.id
    end

    test "a server with watched sync disabled records a skipped run" do
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true
          # connection_settings deliberately absent: this is the exact
          # production state that produced 335 invisible no-op runs.
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      run = Sync.last_run("plex", config.id)

      assert run.status == :skipped
      assert run.skip_reason == "sync_disabled"
    end

    test "a disabled server records a skipped run with its own reason" do
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Off",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: false,
          connection_settings: %{"sync_watched" => "true"}
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("plex", config.id).skip_reason == "server_disabled"
    end
  end
end
