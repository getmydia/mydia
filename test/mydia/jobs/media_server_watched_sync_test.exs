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

  describe "perform/1 with mode server" do
    test "fans out one job per enabled link" do
      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "Server Mode Plex",
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

      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "mode" => "server",
                 "config_id" => server.id
               })

      assert_enqueued(
        worker: MediaServerWatchedSync,
        args: %{"config_id" => server.id, "user_id" => user.id, "link_id" => link.id}
      )
    end

    test "records a skip and enqueues nothing when the server is disabled" do
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

      {:ok, _link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          access_token: "user-token",
          enabled: true
        })

      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "mode" => "server",
                 "config_id" => server.id
               })

      assert Sync.last_run("plex", server.id).skip_reason == "server_disabled"
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
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

    test "a Plex config with watched sync on and a blank token records no_token and enqueues nothing" do
      # token isn't validate_required on MediaServerConfig, so a Plex config
      # saved with sync on but no token would otherwise reach enqueue_linked_users,
      # record :seeding_links every tick, and enqueue a seed job that can never
      # produce a link (PlexLinkSeed.seedable?/1 also requires a token). That is
      # a job reporting healthy while doing nothing forever.
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Tokenless Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("plex", config.id).skip_reason == "no_token"
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
      assert [] = all_enqueued(worker: Mydia.Jobs.PlexLinkSeed)
    end

    test "a config with no links seeds them instead of skipping forever" do
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
      # Now the run seeds links rather than recording :no_user_mapping and
      # stopping, which is what made this job do nothing on every install.
      _u1 = user_fixture()
      _u2 = user_fixture()

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("plex", config.id).skip_reason == "seeding_links"
      assert_enqueued(worker: Mydia.Jobs.PlexLinkSeed, args: %{"config_id" => config.id})

      # Still no per-user job: defaulting to the admin token is the bug this
      # test has always guarded, and seeding must not reintroduce it.
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
    end
  end

  describe "a config deleted between enqueue and execution" do
    setup do
      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Doomed",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          access_token: "user-token",
          enabled: true
        })

      # Capture the ids, then delete. The jobs are already queued at this point
      # in the real failure, so they still carry ids that no longer resolve.
      ids = %{config_id: config.id, user_id: user.id, link_id: link.id}
      {:ok, _} = Settings.delete_media_server_config(config)

      ids
    end

    test "server mode is a no-op rather than three failed retries", ids do
      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "mode" => "server",
                 "config_id" => ids.config_id
               })
    end

    test "per-user mode is a no-op rather than three failed retries", ids do
      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => ids.config_id,
                 "user_id" => ids.user_id,
                 "link_id" => ids.link_id
               })
    end
  end
end
