defmodule Mydia.Plugins.HostFunctionsSyncTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Playback
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Plugin
  alias Mydia.Settings

  @slug "tester"

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Tester",
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => @slug,
          "name" => "Tester",
          "version" => "1.0.0",
          "capabilities" => %{
            "surfaces:write" => ["playback:watched"],
            "data:read" => ["playback_progress"]
          }
        },
        granted_capabilities: %{
          "surfaces:write" => ["playback:watched"],
          "data:read" => ["playback_progress"]
        },
        enabled: true
      })

    user = user_fixture()
    movie = media_item_fixture(%{tmdb_id: "4242", title: "Harbor Lights"})
    {:ok, _} = Connections.connect(@slug, user.id, %{status: "connected", access_token: "t"})
    instance = Instances.default_instance(@slug)

    plugin = %Plugin{
      slug: @slug,
      name: "Tester",
      enabled: true,
      granted_capabilities: %{
        "surfaces:write" => ["playback:watched"],
        "data:read" => ["playback_progress"]
      }
    }

    {:ok, plugin: plugin, instance: instance, user: user, movie: movie}
  end

  describe "origin_tag/2" do
    test "includes the instance id when there is one", %{plugin: p, instance: i} do
      assert HostFunctions.origin_tag(p, i) == "plugin:tester:#{i.id}"
      assert HostFunctions.origin_tag(p, nil) == "plugin:tester"
    end
  end

  describe "writes carry the instance origin" do
    test "set_watch_state tags the progress row", %{plugin: p, instance: i, user: u, movie: m} do
      target = %{
        "user-id": u.id,
        "tmdb-id": {:some, 4242},
        watched: true,
        "position-seconds": {:some, 30},
        "duration-seconds": {:some, 600}
      }

      assert {:ok, %{status: :changed}} = HostFunctions.set_watch_state(p, target, instance: i)
      progress = Playback.get_progress(u.id, media_item_id: m.id)
      assert progress.last_write_origin == "plugin:tester:#{i.id}"
    end
  end

  describe "ensure_watched carries the instance origin" do
    test "on a fresh row", %{plugin: p, instance: i, user: u, movie: m} do
      target = %{"user-id": u.id, "tmdb-id": {:some, 4242}}

      assert {:ok, %{status: :changed}} = HostFunctions.ensure_watched(p, target, instance: i)
      progress = Playback.get_progress(u.id, media_item_id: m.id)
      assert progress.watched
      assert progress.last_write_origin == "plugin:tester:#{i.id}"
    end

    test "on an existing row (mark_watched branch)", %{plugin: p, instance: i, user: u, movie: m} do
      {:ok, _} =
        Playback.save_progress(
          u.id,
          [media_item_id: m.id],
          %{position_seconds: 5, duration_seconds: 600},
          origin: "player"
        )

      target = %{"user-id": u.id, "tmdb-id": {:some, 4242}}

      assert {:ok, %{status: :changed}} = HostFunctions.ensure_watched(p, target, instance: i)
      progress = Playback.get_progress(u.id, media_item_id: m.id)
      assert progress.watched
      assert progress.last_write_origin == "plugin:tester:#{i.id}"
    end
  end

  describe "data_list playback_progress origin" do
    setup %{user: u, movie: m} do
      {:ok, _} =
        Playback.save_progress(
          u.id,
          [media_item_id: m.id],
          %{position_seconds: 5, duration_seconds: 600},
          origin: "player"
        )

      :ok
    end

    test "1.4 marshalling includes origin", %{plugin: p, instance: i} do
      assert {:ok, %{items: [{:"playback-progress", row}]}} =
               HostFunctions.data_list(p, %{namespace: "playback_progress"},
                 with_origin: true,
                 instance: i
               )

      assert row.origin == {:some, "player"}
    end

    test "older marshalling omits the field", %{plugin: p, instance: i} do
      assert {:ok, %{items: [{:"playback-progress", row}]}} =
               HostFunctions.data_list(p, %{namespace: "playback_progress"}, instance: i)

      refute Map.has_key?(row, :origin)
    end
  end

  describe "report_sync_run/3" do
    test "writes a sync_runs row for the instance", %{plugin: p, instance: i} do
      report = %{
        "started-at": "2026-09-29T10:00:00Z",
        "finished-at": "2026-09-29T10:00:30Z",
        status: :partial,
        pulled: 4,
        pushed: 2,
        skipped: 1,
        errors: 1,
        message: {:some, "one link unauthorized"}
      }

      assert :ok = HostFunctions.report_sync_run(p, i, report)
      run = Mydia.Sync.last_run("plugin:tester", i.id)
      assert run.status == :partial
      assert run.direction == :bidirectional
      assert run.counts == %{"pulled" => 4, "pushed" => 2, "skipped" => 1, "errors" => 1}
      assert run.error == "one link unauthorized"
    end

    test "is ungated: a plugin with no grants may report", %{instance: i} do
      bare = %Plugin{slug: @slug, name: "Tester", enabled: true, granted_capabilities: %{}}

      report = %{
        "started-at": "2026-09-29T10:00:00Z",
        "finished-at": "2026-09-29T10:00:01Z",
        status: :ok,
        pulled: 0,
        pushed: 0,
        skipped: 0,
        errors: 0,
        message: :none
      }

      assert :ok = HostFunctions.report_sync_run(bare, i, report)
    end

    test "rejects a malformed timestamp", %{plugin: p, instance: i} do
      report = %{
        "started-at": "yesterday",
        "finished-at": "2026-09-29T10:00:01Z",
        status: :ok,
        pulled: 0,
        pushed: 0,
        skipped: 0,
        errors: 0,
        message: :none
      }

      assert {:error, %Error{type: :invalid_request}} =
               HostFunctions.report_sync_run(p, i, report)
    end
  end
end
