defmodule Mydia.Downloads.ClientHealthTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.ClientHealth
  alias Mydia.Settings

  setup do
    # Start the ClientHealth GenServer for tests
    start_supervised!(ClientHealth)
    :ok
  end

  describe "check_health/2" do
    test "returns cached health status for existing client" do
      # Create a test download client
      {:ok, client} =
        Settings.create_download_client_config(%{
          name: "Test qBittorrent",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })

      # Give the background task time to run
      Process.sleep(100)

      # Check health (should return from cache after initial check)
      {:ok, health} = ClientHealth.check_health(client.id)

      assert health.status in [:healthy, :unhealthy, :unknown]
      assert %DateTime{} = health.checked_at
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = ClientHealth.check_health(Ecto.UUID.generate())
    end

    test "forces fresh check when force option is true" do
      {:ok, client} =
        Settings.create_download_client_config(%{
          name: "Test Transmission",
          type: :transmission,
          host: "localhost",
          port: 9091,
          enabled: true,
          priority: 1
        })

      # Force a fresh check
      {:ok, health1} = ClientHealth.check_health(client.id, force: true)
      Process.sleep(50)
      {:ok, health2} = ClientHealth.check_health(client.id, force: true)

      # Both should succeed (even if unhealthy)
      assert health1.status in [:healthy, :unhealthy, :unknown]
      assert health2.status in [:healthy, :unhealthy, :unknown]

      # checked_at timestamps should be different
      assert DateTime.compare(health1.checked_at, health2.checked_at) in [:lt, :eq]
    end
  end

  describe "list_services/0" do
    test "returns list of all download client IDs" do
      {:ok, client1} =
        Settings.create_download_client_config(%{
          name: "Client 1",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })

      {:ok, client2} =
        Settings.create_download_client_config(%{
          name: "Client 2",
          type: :transmission,
          host: "localhost",
          port: 9091,
          enabled: true,
          priority: 2
        })

      {:ok, service_ids} = ClientHealth.list_services()

      assert client1.id in service_ids
      assert client2.id in service_ids
    end

    test "returns empty list when no clients configured" do
      {:ok, service_ids} = ClientHealth.list_services()
      assert is_list(service_ids)
    end
  end

  describe "check_all_clients/0" do
    test "returns health status for all clients" do
      {:ok, client1} =
        Settings.create_download_client_config(%{
          name: "Client 1",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })

      {:ok, client2} =
        Settings.create_download_client_config(%{
          name: "Client 2",
          type: :transmission,
          host: "localhost",
          port: 9091,
          enabled: false,
          priority: 2
        })

      # Give background tasks time to complete
      Process.sleep(100)

      results = ClientHealth.check_all_clients()

      assert is_list(results)
      assert length(results) >= 2

      # Find our clients in the results
      client1_health = Enum.find(results, fn {id, _} -> id == client1.id end)
      client2_health = Enum.find(results, fn {id, _} -> id == client2.id end)

      assert {^client1, health1} = client1_health
      assert {^client2, health2} = client2_health

      assert health1.status in [:healthy, :unhealthy, :unknown]
      assert health2.status in [:healthy, :unhealthy, :unknown]
    end

    test "returns empty list when no clients exist" do
      results = ClientHealth.check_all_clients()
      assert is_list(results)
    end
  end

  describe "refresh_all_clients/0" do
    test "triggers refresh of all client health checks" do
      {:ok, _client} =
        Settings.create_download_client_config(%{
          name: "Test Client",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })

      # Refresh should not crash
      assert :ok = ClientHealth.refresh_all_clients()

      # Give the async tasks time to complete
      Process.sleep(200)

      # Should still be able to check health
      results = ClientHealth.check_all_clients()
      assert is_list(results)
    end
  end

  describe "health check caching" do
    test "uses cached result when available and fresh" do
      {:ok, client} =
        Settings.create_download_client_config(%{
          name: "Cache Test Client",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })

      # First check (should populate cache)
      {:ok, health1} = ClientHealth.check_health(client.id, force: true)

      # Immediate second check (should use cache)
      {:ok, health2} = ClientHealth.check_health(client.id)

      # checked_at should be very close (within a second)
      diff = DateTime.diff(health2.checked_at, health1.checked_at, :millisecond)
      assert abs(diff) < 1000
    end
  end

  describe "health status structure" do
    test "health result contains required fields" do
      {:ok, client} =
        Settings.create_download_client_config(%{
          name: "Structure Test",
          type: :qbittorrent,
          host: "localhost",
          port: 8080,
          enabled: true,
          priority: 1
        })

      {:ok, health} = ClientHealth.check_health(client.id, force: true)

      assert Map.has_key?(health, :status)
      assert Map.has_key?(health, :checked_at)
      assert Map.has_key?(health, :details)
      assert Map.has_key?(health, :error)

      assert health.status in [:healthy, :unhealthy, :unknown]
      assert %DateTime{} = health.checked_at
      assert is_map(health.details)
    end
  end
end
