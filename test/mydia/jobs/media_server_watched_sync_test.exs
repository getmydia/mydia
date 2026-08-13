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
          remote_user_id: "1",
          remote_username: user.username,
          access_token: "user-token",
          enabled: true
        })

      # The link is the thing being fanned out over, so it has to actually name
      # an account. These fields were written as plex_account_id/plex_username,
      # which `cast/3` drops in silence, and the row went in with a nil identity
      # while the assertions below still passed.
      assert link.remote_user_id == "1"
      assert link.remote_username == user.username

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

      link = link_fixture(server, user)

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => server.id,
                 "user_id" => user.id,
                 "link_id" => link.id
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

      link = link_fixture(server, user)

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => server.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })
    end

    test "runs a real Jellyfin sync to completion instead of skipping it as unsupported" do
      # Regression test for the reported bug: this used to fall through
      # provider_for/1's catch-all and record :unsupported_provider, badging
      # Completed while syncing nothing. A Bypass-backed server proves the
      # job actually drives Mydia.WatchSync end-to-end for Jellyfin, not just
      # that provider_for/1 resolves.
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"Items" => [], "TotalRecordCount" => 0}))
      end)

      user = user_fixture()

      {:ok, server} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "jf1",
          remote_username: user.username,
          enabled: true
        })

      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => server.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      assert %{status: :ok, skip_reason: nil} = Sync.last_run("jellyfin", server.id)
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

      link = link_fixture(config, user)

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
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

    test "an individual job carrying no link is refused, never scoped to the server's own token" do
      # "Sync now" used to enqueue exactly this shape. Resolving it to
      # config.token made whoever pressed the button read and write the server
      # owner's watch state, the same cross-account merge per-user links exist
      # to prevent, through a producer no per-task review looked at.
      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "owner-token",
          enabled: true,
          connection_settings: %{"sync_watched" => "true"}
        })

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id
               })

      run = Sync.last_run("plex", config.id)
      assert run.status == :skipped
      assert run.skip_reason == "link_not_found"
    end

    test "a job whose link has a remote user id but no Plex token never runs under the admin token" do
      # A GUID-only link is a valid Jellyfin-shaped identity, but Plex identity
      # IS the per-user token: this scope must be refused by the provider
      # rather than silently proceeding on config.token, the admin's own
      # credential. That silent fallback is exactly the merge bug per-user
      # links exist to prevent.
      #
      # A mapping row is seeded, and the config carries a fresh
      # last_mapping_refresh_at, so the sync skips its (legitimately
      # admin-token-scoped) refresh crawl and calls straight into
      # `list_changes/3`, which is the call this test is guarding. Without
      # both, the assertion below could not tell a correct refusal apart from
      # an unrelated connection failure against a URL with no real server.
      user = user_fixture()
      media_item = insert(:media_item)

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "admin-token",
          enabled: true,
          connection_settings: %{
            "sync_watched" => "true",
            "last_mapping_refresh_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
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

      # Recorded as a skip, not returned as an error. A missing credential is a
      # misconfiguration no retry can fix: as an error it burned all three Oban
      # attempts and landed in `discarded`, which is the exact disappearance the
      # user reported.
      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      run = Sync.last_run("plex", config.id)
      assert run.status == :skipped
      assert run.skip_reason == "missing_user_token"
      assert run.finished_at

      # The run already open for this attempt became the skip. A second row
      # would leave an unfinished `:ok` run behind saying the opposite, and the
      # admin page reads whichever landed last.
      assert Repo.aggregate(Mydia.Sync.Run, :count) == 1
    end

    test "a Jellyfin link naming no account is recorded as a skip, not a retryable error" do
      # The Jellyfin half of the same misconfiguration: identity there is the
      # account GUID rather than a token, and its absence is just as permanent.
      bypass = Bypass.open()
      user = user_fixture()
      media_item = insert(:media_item)

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{
            "sync_watched" => "true",
            "last_mapping_refresh_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })

      # A token with no GUID is a valid-looking link that Jellyfin cannot use.
      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: nil,
          access_token: "leftover-token",
          enabled: true
        })

      # Seeded so the run skips its refresh crawl (the config above also
      # carries a fresh last_mapping_refresh_at) and calls straight into
      # list_changes/3, the call under test.
      {:ok, _mapping} =
        %Mapping{}
        |> Mapping.changeset(%{
          provider: "jellyfin",
          provider_instance_id: config.id,
          media_item_id: media_item.id,
          remote_id: "jf1"
        })
        |> Repo.insert()

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      run = Sync.last_run("jellyfin", config.id)
      assert run.status == :skipped
      assert run.skip_reason == "missing_remote_user_id"
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

    test "a Plex config with watched sync on and a blank token records no_token and enqueues nothing" do
      # token isn't validate_required on MediaServerConfig, so a Plex config
      # saved with sync on but no token would otherwise reach enqueue_linked_users,
      # record :seeding_links every tick, and enqueue a seed job that can never
      # produce a link (MediaServerLinkSeed.seedable?/1 also requires a token). That is
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
      assert [] = all_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed)
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
      assert_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed, args: %{"config_id" => config.id})

      # Still no per-user job: defaulting to the admin token is the bug this
      # test has always guarded, and seeding must not reintroduce it.
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
    end

    test "a server that has already been seeded and now has no links is left alone" do
      # Seeding is a first run, not a repair. The mapping modal promises that
      # clearing a mapping stops watched sync for that user; re-seeding on the
      # next tick would put every one of them back.
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Seeded Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{
            "sync_watched" => "true",
            "plex_links_seeded_at" => "2026-08-12T00:00:00Z"
          }
        })

      _user = user_fixture()

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("plex", config.id).skip_reason == "no_user_mapping"
      assert [] = all_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed)
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
    end

    test "a transient seeding failure is retried rather than treated as terminal" do
      # link_seeding_failed means the server was unreachable, which is exactly
      # the kind of thing that fixes itself. Only a completed pass stamps the
      # config, so an unstamped one is always worth another try.
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => "true"}
        })

      Sync.record_skip(
        %{provider: "plex", provider_instance_id: config.id, user_id: nil},
        :link_seeding_failed
      )

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("plex", config.id).skip_reason == "seeding_links"
      assert_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed, args: %{"config_id" => config.id})
    end

    # Jellyfin seeds by username match the same way Plex does, so a link-less
    # Jellyfin server queues a seed rather than sitting on :no_user_mapping
    # forever. The invariant both providers share is the one that matters: no
    # link, no per-user job, so nothing ever runs against the server's own
    # credential.
    test "a Jellyfin config with no links seeds them and enqueues no per-user job" do
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => "true"}
        })

      _u1 = user_fixture()
      _u2 = user_fixture()

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("jellyfin", config.id).skip_reason == "seeding_links"
      assert_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed, args: %{"config_id" => config.id})
      assert [] = all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
    end

    test "a seeded Jellyfin server with no links is left alone too" do
      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          enabled: true,
          connection_settings: %{
            "sync_watched" => "true",
            "plex_links_seeded_at" => "2026-08-12T00:00:00Z"
          }
        })

      _u1 = user_fixture()

      assert :ok = perform_job(MediaServerWatchedSync, %{"mode" => "all_enabled"})

      assert Sync.last_run("jellyfin", config.id).skip_reason == "no_user_mapping"
      assert [] = all_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed)
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

  describe "mapping refresh staleness" do
    setup do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"Items" => [], "TotalRecordCount" => 0}))
      end)

      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      link = link_fixture(config, user)

      {:ok, config: config, user: user, link: link}
    end

    test "a server that has never crawled claims a refresh", ctx do
      refute Map.has_key?(ctx.config.connection_settings, "last_mapping_refresh_at")

      config = run(ctx.config, ctx.user, ctx.link)

      assert is_binary(config.connection_settings["last_mapping_refresh_at"])
    end

    test "a fresh stamp is left alone on the next run", ctx do
      # A stamp within the last second would pass this assertion even if
      # every run re-claimed unconditionally, since both timestamps would
      # print identically at second precision. Seeding one an hour old (well
      # inside the 24h window, so refresh_mode/1 reads :auto) and asserting
      # byte-identity against the seeded string is what actually exercises
      # "an :auto run must leave the stamp untouched".
      fresh =
        DateTime.utc_now()
        |> DateTime.add(-1 * 60 * 60, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      {:ok, config} =
        Settings.update_media_server_config(ctx.config, %{
          connection_settings:
            Map.put(ctx.config.connection_settings, "last_mapping_refresh_at", fresh)
        })

      config = run(config, ctx.user, ctx.link)

      assert config.connection_settings["last_mapping_refresh_at"] == fresh
    end

    test "a stamp older than the interval is refreshed", ctx do
      stale =
        DateTime.utc_now()
        |> DateTime.add(-25 * 60 * 60, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      {:ok, config} =
        Settings.update_media_server_config(ctx.config, %{
          connection_settings:
            Map.put(ctx.config.connection_settings, "last_mapping_refresh_at", stale)
        })

      config = run(config, ctx.user, ctx.link)

      stamp = config.connection_settings["last_mapping_refresh_at"]
      assert stamp != stale
      # A bug writing a garbage string would still change the value and pass
      # the inequality check above; this proves the new value actually parses.
      assert {:ok, _, _} = DateTime.from_iso8601(stamp)
    end

    test "an unreadable stamp is treated as never crawled", ctx do
      {:ok, config} =
        Settings.update_media_server_config(ctx.config, %{
          connection_settings:
            Map.put(ctx.config.connection_settings, "last_mapping_refresh_at", "not-a-timestamp")
        })

      config = run(config, ctx.user, ctx.link)

      stamp = config.connection_settings["last_mapping_refresh_at"]
      assert stamp != "not-a-timestamp"
      # A bug writing a garbage string would still change the value and pass
      # the inequality check above; this proves the new value actually parses.
      assert {:ok, _, _} = DateTime.from_iso8601(stamp)
    end

    test "a future stamp (clock skew) forces a crawl instead of pinning to auto", ctx do
      future =
        DateTime.utc_now()
        |> DateTime.add(60 * 60, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      {:ok, config} =
        Settings.update_media_server_config(ctx.config, %{
          connection_settings:
            Map.put(ctx.config.connection_settings, "last_mapping_refresh_at", future)
        })

      config = run(config, ctx.user, ctx.link)

      stamp = config.connection_settings["last_mapping_refresh_at"]
      assert stamp != future
      assert {:ok, _, _} = DateTime.from_iso8601(stamp)
    end

    test "claiming a refresh does not clobber the last sync timestamp", ctx do
      config = run(ctx.config, ctx.user, ctx.link)

      assert is_binary(config.connection_settings["last_mapping_refresh_at"])
      assert is_binary(config.connection_settings["last_watched_sync_at"])
    end
  end

  describe "mapping refresh forces a crawl" do
    # No block-level setup here, deliberately: the block above's `setup`
    # creates its own Bypass server before every test regardless of arity,
    # and this test needs to control its Bypass instance precisely (to count
    # hits), so it stays self-contained instead.
    test "an auto run skips the crawl a forced run performs, per the /Items hit count" do
      # Every test in the block above only asserts on the connection_settings
      # stamp, which claim_mapping_refresh/2 writes independently of the
      # `refresh_mappings: refresh` option threaded to WatchSync.sync/4. That
      # leaves nothing distinguishing :auto from :force: this test does, by
      # counting real Jellyfin /Items calls. A seeded mapping makes engine.ex's
      # mapped_any?/2 true, so an :auto run calls /Items once (list_changes
      # only); a :force run calls it twice (refresh_mappings's crawl, then
      # list_changes).
      bypass = Bypass.open()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"Items" => [], "TotalRecordCount" => 0}))
      end)

      user = user_fixture()
      media_item = insert(:media_item)

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{
            "sync_watched" => true,
            "last_mapping_refresh_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })

      link = link_fixture(config, user)

      {:ok, _mapping} =
        %Mapping{}
        |> Mapping.changeset(%{
          provider: "jellyfin",
          provider_instance_id: config.id,
          media_item_id: media_item.id,
          remote_id: "jf1"
        })
        |> Repo.insert()

      auto_config = run(config, user, link)
      assert Agent.get(counter, & &1) == 1

      stale =
        DateTime.utc_now()
        |> DateTime.add(-25 * 60 * 60, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      {:ok, forced_config} =
        Settings.update_media_server_config(auto_config, %{
          connection_settings:
            Map.put(auto_config.connection_settings, "last_mapping_refresh_at", stale)
        })

      run(forced_config, user, link)
      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "mapping refresh claim is undone on a general failure" do
    test "a crawl failure restores the pre-claim stamp instead of burning the 24h window" do
      # No last_mapping_refresh_at at all, so refresh_mode/1 returns :force and
      # claim_mapping_refresh/2 stamps it before WatchSync.sync/4 runs. The
      # crawl (Engine.maybe_refresh/5, the first thing sync/4 does) then fails
      # against a 500, landing in run_sync/2's general {:error, reason} clause.
      # Without the fix, the claimed stamp would stay written, and the next
      # tick's refresh_mode/1 would read it as fresh and silently skip the
      # crawl it still owes.
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      link = link_fixture(config, user)

      refute Map.has_key?(config.connection_settings, "last_mapping_refresh_at")

      assert {:error, _reason} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      reloaded = Settings.get_media_server_config!(config.id)

      refute Map.has_key?(reloaded.connection_settings, "last_mapping_refresh_at")

      # The run itself is still recorded as a failure, same as before the fix.
      run = Sync.last_run("jellyfin", config.id)
      assert run.status == :error
    end

    test "a stale stamp is restored to its previous value, not merely cleared" do
      stale =
        DateTime.utc_now()
        |> DateTime.add(-25 * 60 * 60, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true, "last_mapping_refresh_at" => stale}
        })

      link = link_fixture(config, user)

      assert {:error, _reason} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      reloaded = Settings.get_media_server_config!(config.id)

      assert reloaded.connection_settings["last_mapping_refresh_at"] == stale
    end

    test "a @misconfigured error keeps the claimed stamp, since the crawl already succeeded" do
      # missing_remote_user_id surfaces from list_changes/3, which only runs
      # after maybe_refresh/5 (the crawl) already completed. Restoring the
      # stamp here would force a full re-crawl on every 30-minute tick for as
      # long as the link stays unmapped, which is exactly the cost the 24h
      # interval exists to avoid.
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/Items", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"Items" => [], "TotalRecordCount" => 0}))
      end)

      user = user_fixture()

      {:ok, config} =
        Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      # No remote_user_id: list_changes/3 fails with :missing_remote_user_id,
      # but only after the crawl (forced because no stamp exists yet) runs.
      {:ok, link} =
        Settings.upsert_media_server_user_link(%{
          media_server_config_id: config.id,
          user_id: user.id,
          remote_user_id: nil,
          access_token: "leftover-token",
          enabled: true
        })

      refute Map.has_key?(config.connection_settings, "last_mapping_refresh_at")

      assert {:ok, :skipped} =
               perform_job(MediaServerWatchedSync, %{
                 "config_id" => config.id,
                 "user_id" => user.id,
                 "link_id" => link.id
               })

      reloaded = Settings.get_media_server_config!(config.id)

      assert is_binary(reloaded.connection_settings["last_mapping_refresh_at"])

      run = Sync.last_run("jellyfin", config.id)
      assert run.status == :skipped
      assert run.skip_reason == "missing_remote_user_id"
    end
  end

  defp link_fixture(config, user, attrs \\ %{}) do
    {:ok, link} =
      Settings.upsert_media_server_user_link(
        Map.merge(
          %{
            media_server_config_id: config.id,
            user_id: user.id,
            remote_user_id: "remote-#{System.unique_integer([:positive])}",
            remote_username: user.username,
            access_token: "user-token",
            enabled: true
          },
          attrs
        )
      )

    link
  end

  defp run(config, user, link) do
    assert :ok =
             perform_job(MediaServerWatchedSync, %{
               "config_id" => config.id,
               "user_id" => user.id,
               "link_id" => link.id
             })

    Settings.get_media_server_config!(config.id)
  end
end
