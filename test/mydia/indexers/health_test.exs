defmodule Mydia.Indexers.HealthTest do
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Health
  alias Mydia.Settings

  describe "status_map/1" do
    test "reports disabled indexers as :disabled without a network call" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Disabled Indexer",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: false
        })

      map = Health.status_map([indexer])
      assert map[indexer.id].status == :disabled
    end

    test "reports :unknown on cache miss without probing" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Unchecked Indexer",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: true
        })

      map = Health.status_map([indexer])
      assert map[indexer.id].status == :unknown
    end
  end

  describe "check_health/2 for unknown indexers" do
    test "returns :not_found for a missing database id" do
      assert {:error, :not_found} = Health.check_health(Ecto.UUID.generate(), force: true)
    end

    test "returns :not_found for a runtime-form id that is not configured" do
      id = "runtime::indexer::no-such-indexer"

      assert {:error, :not_found} = Health.check_health(id)
      assert {:error, :not_found} = Health.check_health(id, force: true)
    end
  end

  describe "startup" do
    # init/1 runs before Mydia.Application registers the indexer adapters, so a
    # probe from there fails every indexer as an unknown type on every boot.
    test "starting the monitor does not probe; refresh_all_indexers/0 does" do
      bypass = Bypass.open()
      test_pid = self()

      Bypass.stub(bypass, "GET", "/api/v1/system/status", fn conn ->
        send(test_pid, :probed)
        Plug.Conn.resp(conn, 500, "")
      end)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Startup Prowlarr",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: true
        })

      start_supervised!(Health)
      refute_receive :probed, 300

      Health.refresh_all_indexers()
      assert_receive :probed, 2_000

      # Let the probe task finish before the monitor (and its ETS tables) stops.
      assert wait_until(fn -> Health.status_map([indexer])[indexer.id].status != :unknown end)
    end

    defp wait_until(fun, attempts \\ 40) do
      cond do
        fun.() -> true
        attempts == 0 -> false
        true -> Process.sleep(50) && wait_until(fun, attempts - 1)
      end
    end
  end

  describe "indexers cooling down after HTTP 429" do
    alias Mydia.Indexers.RateLimiter

    defp reporting_newznab(name) do
      test_pid = self()
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api", fn conn ->
        send(test_pid, {:probed, name})
        Plug.Conn.resp(conn, 500, "")
      end)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: name,
          type: :newznab,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: true
        })

      on_exit(fn -> RateLimiter.clear_indexer(indexer.id) end)
      indexer
    end

    test "the scheduled check sends a cooling indexer nothing" do
      start_supervised!(Health)
      cooling = reporting_newznab("Cooling Feed")
      open = reporting_newznab("Open Feed")
      RateLimiter.record_rate_limited(cooling.id, nil)

      Health.refresh_all_indexers()

      assert_receive {:probed, "Open Feed"}, 2_000
      refute_receive {:probed, "Cooling Feed"}, 300
      assert Health.get_failure_count(cooling.id) == 0

      # Let the open feed's task finish before the monitor stops.
      assert wait_until(fn -> Health.status_map([open])[open.id].status != :unknown end)
    end

    test "an uncached check of a cooling indexer is neither healthy nor a failure" do
      start_supervised!(Health)
      cooling = reporting_newznab("Cooling Feed")
      RateLimiter.record_rate_limited(cooling.id, nil)

      assert {:ok, %{status: :unknown, error: "Cooling down after HTTP 429 until " <> _}} =
               Health.check_health(cooling.id)

      refute_receive {:probed, _}, 100
      assert Health.get_failure_count(cooling.id) == 0
    end
  end

  describe "paused Prowlarr indexers" do
    test "a healthy Prowlarr check carries the paused list in details" do
      start_supervised!(Health)
      bypass = Bypass.open()
      till = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()

      Mydia.IndexerMock.mock_prowlarr_status(bypass,
        indexer_status: [%{"indexerId" => 1, "disabledTill" => till}]
      )

      Mydia.IndexerMock.mock_prowlarr_indexers(bypass)

      {:ok, indexer} =
        Settings.create_indexer_config(%{
          name: "Paused Prowlarr",
          type: :prowlarr,
          base_url: "http://localhost:#{bypass.port}",
          api_key: "key",
          enabled: true
        })

      assert {:ok, %{status: :healthy, details: details}} =
               Health.check_health(indexer.id, force: true)

      assert [%{id: 1, name: "Fictional Tracker"}] = details.paused_indexers
    end
  end
end
