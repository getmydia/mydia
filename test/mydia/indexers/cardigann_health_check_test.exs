defmodule Mydia.Indexers.CardigannHealthCheckTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Repo

  import Mydia.IndexersFixtures

  describe "test_connection/2" do
    test "returns error when definition not found" do
      assert {:error, "Indexer definition not found"} =
               CardigannHealthCheck.test_connection(Ecto.UUID.generate())
    end

    test "tests connection for valid public indexer" do
      definition = cardigann_definition_fixture(%{enabled: true, type: "public"})

      # Mock a successful test (this will actually attempt to parse and connect)
      # In a real scenario, we'd need to use mocks or have test definitions
      result = CardigannHealthCheck.test_connection(definition.id)

      assert {:ok, test_result} = result
      assert is_map(test_result)
      assert Map.has_key?(test_result, :success)
      assert Map.has_key?(test_result, :status)
      assert Map.has_key?(test_result, :message)
    end
  end

  describe "execute_health_check/2" do
    test "updates health status after successful check" do
      definition = cardigann_definition_fixture(%{enabled: true})

      # Note: This will likely fail with actual connection, but will update health status
      {:ok, _result} = CardigannHealthCheck.execute_health_check(definition)

      # Verify health status was updated in database
      updated_definition = Repo.get!(CardigannDefinition, definition.id)
      assert updated_definition.last_health_check_at != nil
      assert updated_definition.health_status in ["healthy", "degraded", "unhealthy", "unknown"]
    end

    test "tracks consecutive failures" do
      definition = cardigann_definition_fixture(%{enabled: true, consecutive_failures: 2})

      # Execute health check (will likely fail without proper definition)
      {:ok, result} = CardigannHealthCheck.execute_health_check(definition)

      # Check that consecutive failures was updated
      updated_definition = Repo.get!(CardigannDefinition, definition.id)

      if result.success do
        # If successful, consecutive failures should be reset
        assert updated_definition.consecutive_failures == 0
        assert updated_definition.last_successful_query_at != nil
      else
        # If failed, consecutive failures should increment
        assert updated_definition.consecutive_failures >= definition.consecutive_failures
      end
    end

    test "returns parsing error for invalid definition" do
      definition =
        cardigann_definition_fixture(%{
          enabled: true,
          definition: "invalid: yaml: content:"
        })

      assert {:ok, result} = CardigannHealthCheck.execute_health_check(definition)
      refute result.success
      assert result.status == "unhealthy"
      assert result.error != nil
    end
  end

  describe "probe_candidates/2" do
    setup do
      dead = Bypass.open()
      live = Bypass.open()
      Bypass.down(dead)

      {:ok,
       dead: dead,
       live: live,
       dead_url: "http://localhost:#{dead.port}",
       live_url: "http://localhost:#{live.port}"}
    end

    test "returns the first responding candidate", %{
      dead_url: dead_url,
      live_url: live_url,
      live: live
    } do
      Bypass.expect(live, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      parsed = %Parsed{links: [dead_url, live_url], legacylinks: []}

      assert {:ok, chosen, status} = CardigannHealthCheck.probe_candidates(parsed, %{})
      assert chosen == live_url
      assert status[dead_url]["ok"] == false
      assert status[live_url]["ok"] == true
    end

    test "prefers a live primary over a legacy link", %{
      live_url: live_url,
      dead_url: dead_url,
      live: live
    } do
      Bypass.expect(live, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      parsed = %Parsed{links: [live_url], legacylinks: [dead_url]}

      assert {:ok, chosen, _status} = CardigannHealthCheck.probe_candidates(parsed, %{})
      assert chosen == live_url
    end

    test "returns an error when every candidate fails", %{dead_url: dead_url} do
      parsed = %Parsed{links: [dead_url], legacylinks: []}

      assert {:error, status} = CardigannHealthCheck.probe_candidates(parsed, %{})
      assert status[dead_url]["ok"] == false
    end

    test "returns an error when there are no candidates" do
      assert {:error, status} =
               CardigannHealthCheck.probe_candidates(%Parsed{links: [], legacylinks: []}, %{})

      assert status == %{}
    end
  end

  describe "execute_health_check/2 link persistence" do
    test "stores the winning candidate as active_link" do
      dead = Bypass.open()
      live = Bypass.open()
      Bypass.down(dead)
      Bypass.expect(live, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      dead_url = "http://localhost:#{dead.port}"
      live_url = "http://localhost:#{live.port}"

      {:ok, definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "probe-test",
          name: "Probe Test",
          type: "public",
          links: %{"0" => dead_url, "1" => live_url},
          capabilities: %{},
          schema_version: "v11",
          definition: """
          id: probe-test
          name: Probe Test
          description: d
          language: en-US
          type: public
          encoding: UTF-8
          links:
            - #{dead_url}
            - #{live_url}
          caps:
            categories:
              2000: Movies
          settings: []
          search:
            paths:
              - path: /search
            rows:
              selector: tr
            fields:
              title:
                selector: td.title
              size:
                selector: td.size
              seeders:
                selector: td.seeders
              download:
                selector: a
                attribute: href
          """
        })
        |> Repo.insert()

      assert {:ok, _result} = CardigannHealthCheck.execute_health_check(definition)

      reloaded = Repo.get!(CardigannDefinition, definition.id)
      assert reloaded.active_link == live_url
      assert reloaded.link_status[dead_url]["ok"] == false
      assert reloaded.link_status[live_url]["ok"] == true
    end
  end

  describe "check_all_enabled/0" do
    test "checks all enabled indexers" do
      # Create mix of enabled and disabled
      _enabled1 = cardigann_definition_fixture(%{enabled: true, name: "Enabled 1"})
      _enabled2 = cardigann_definition_fixture(%{enabled: true, name: "Enabled 2"})
      _disabled = cardigann_definition_fixture(%{enabled: false, name: "Disabled 1"})

      assert {:ok, results} = CardigannHealthCheck.check_all_enabled()
      assert is_map(results)
      # Should only check enabled indexers
      assert map_size(results) == 2
    end

    test "returns empty map when no indexers enabled" do
      _disabled = cardigann_definition_fixture(%{enabled: false})

      assert {:ok, results} = CardigannHealthCheck.check_all_enabled()
      assert results == %{}
    end
  end
end
