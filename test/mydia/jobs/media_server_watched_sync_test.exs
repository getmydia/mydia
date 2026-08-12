defmodule Mydia.Jobs.MediaServerWatchedSyncTest do
  use Mydia.DataCase
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.Settings
  alias Mydia.Sync
  alias Mydia.WatchSync.Mapping

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
          remote_user_id: "1",
          remote_username: user.username,
          access_token: "user-token",
          enabled: true
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert_enqueued(
        worker: MediaServerWatchedSync,
        args: %{"config_id" => server.id, "user_id" => user.id, "link_id" => link.id}
      )
    end

    test "treats unrecognised args as a scheduler run instead of raising" do
      assert :ok = perform_job(MediaServerWatchedSync, %{})
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

    test "a job whose link has no usable identity is skipped, never run on the admin token" do
      # Falling back to config.token here would sync this user against the
      # admin's Plex watch state, which is the merge bug per-user links exist to
      # prevent. Task 8 refuses to create identity-less links; this is the
      # matching guard on the consuming side.
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
          remote_user_id: nil,
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
      assert run.skip_reason == "link_identity_missing"
    end

    test "a job whose link has a remote user id but no Plex token never runs under the admin token" do
      # A GUID-only link is a valid Jellyfin-shaped identity, but Plex identity
      # IS the per-user token: this scope must be refused by the provider
      # rather than silently proceeding on config.token, the admin's own
      # credential. That silent fallback is exactly the merge bug per-user
      # links exist to prevent.
      #
      # A mapping row is seeded so the sync skips its (legitimately
      # admin-token-scoped) refresh crawl and calls straight into
      # `list_changes/3`, which is the call this test is guarding. Without it,
      # the assertion below could not tell a correct refusal apart from an
      # unrelated connection failure against a URL with no real server.
      user = user_fixture()
      media_item = insert(:media_item)

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
          remote_user_id: "2",
          access_token: nil,
          enabled: true
        })

      {:ok, _mapping} =
        %Mapping{}
        |> Mapping.changeset(%{
          provider: "plex",
          provider_instance_id: config.id,
          media_item_id: media_item.id,
          remote_id: "rk1"
        })
        |> Repo.insert()

      assert {:error, :missing_user_token} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      run = Sync.last_run("plex", config.id)
      assert run.status == :error
      assert run.error =~ "missing_user_token"
    end

    test "a job whose link id does not resolve to any link is refused, distinctly from a missing identity" do
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

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => Ecto.UUID.generate()
               })

      assert Sync.last_run("plex", config.id).skip_reason == "link_not_found"
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
          remote_user_id: "1",
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

    test "skips a link that carries neither a token nor a remote user id" do
      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          enabled: true
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => server.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      assert %{status: :skipped, skip_reason: "link_identity_missing"} =
               Sync.last_run("jellyfin", server.id)
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

    test "does not skip a Jellyfin server as an unsupported provider" do
      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, _link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "jf1",
          remote_username: user.username,
          enabled: true
        })

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      refute match?(%{skip_reason: "unsupported_provider"}, Sync.last_run("jellyfin", server.id))
    end
  end
end
