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

      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          plex_account_id: "1",
          plex_username: user.username,
          access_token: "user-token",
          enabled: true
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert_enqueued(
        worker: MediaServerWatchedSync,
        args: %{"config_id" => server.id, "user_id" => user.id, "link_id" => link.id}
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

    test "a job whose link has no usable token is skipped, never run on the admin token" do
      # Falling back to config.token here would sync this user against the
      # admin's Plex watch state, which is the merge bug per-user links exist to
      # prevent. Task 8 refuses to create tokenless links; this is the matching
      # guard on the consuming side.
      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "admin-token",
          enabled: true,
          connection_settings: %{"sync_watched" => "true"}
        })

      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          plex_account_id: "2",
          access_token: nil,
          enabled: true
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      run = Sync.last_run("plex", config.id)
      assert run.status == :skipped
      assert run.skip_reason == "link_token_missing"
    end

    test "a job whose link belongs to another user is refused" do
      # Resolving a token by link id alone would pair user A with user B's
      # token, reintroducing the cross-account merge from the other direction.
      owner = user_fixture()
      other = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "admin-token",
          enabled: true,
          connection_settings: %{"sync_watched" => "true"}
        })

      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: owner.id,
          plex_account_id: "1",
          access_token: "owner-token",
          enabled: true
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => other.id,
                 "link_id" => link.id
               })

      assert Sync.last_run("plex", config.id).skip_reason == "link_user_mismatch"
    end

    test "a user with no link is skipped with a reason rather than defaulted" do
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => "true"}
        })

      # Three users exist, none linked. Previously all three would sync against
      # the single admin token, merging their histories into one Plex account.
      _u1 = user_fixture()
      _u2 = user_fixture()

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("plex", config.id).skip_reason == "no_user_mapping"
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
    end
  end
end
