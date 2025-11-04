defmodule Mydia.HealthTest do
  use ExUnit.Case, async: true

  alias Mydia.Health

  defmodule TestHealthProvider do
    @moduledoc false

    def check_health("service-1") do
      {:ok,
       %{
         status: :healthy,
         checked_at: DateTime.utc_now(),
         details: %{version: "1.0.0"},
         error: nil
       }}
    end

    def check_health("service-2") do
      {:ok,
       %{
         status: :unhealthy,
         checked_at: DateTime.utc_now(),
         details: %{},
         error: "Connection refused"
       }}
    end

    def check_health(_) do
      {:error, :not_found}
    end

    def list_services do
      {:ok, ["service-1", "service-2"]}
    end
  end

  describe "register_provider/2" do
    test "registers a health check provider for a service type" do
      assert :ok = Health.register_provider(:test_service, TestHealthProvider)

      # Verify we can retrieve the provider
      providers = Health.list_providers()
      assert :test_service in providers
    end

    test "allows multiple provider registrations" do
      assert :ok = Health.register_provider(:service_a, TestHealthProvider)
      assert :ok = Health.register_provider(:service_b, TestHealthProvider)

      providers = Health.list_providers()
      assert :service_a in providers
      assert :service_b in providers
    end
  end

  describe "check_health/2" do
    setup do
      Health.register_provider(:test_service, TestHealthProvider)
      :ok
    end

    test "performs health check for registered service" do
      {:ok, health} = Health.check_health(:test_service, "service-1")

      assert health.status == :healthy
      assert health.details.version == "1.0.0"
      assert health.error == nil
      assert %DateTime{} = health.checked_at
    end

    test "returns unhealthy status when service is down" do
      {:ok, health} = Health.check_health(:test_service, "service-2")

      assert health.status == :unhealthy
      assert health.error == "Connection refused"
      assert %DateTime{} = health.checked_at
    end

    test "returns error when provider not registered" do
      assert {:error, :no_provider_registered} =
               Health.check_health(:nonexistent_service, "any-id")
    end

    test "returns error when service not found" do
      assert {:error, :not_found} = Health.check_health(:test_service, "nonexistent-service")
    end
  end

  describe "check_all/1" do
    setup do
      Health.register_provider(:test_service, TestHealthProvider)
      :ok
    end

    test "checks health for all services of a given type" do
      results = Health.check_all(:test_service)

      assert is_list(results)
      assert length(results) == 2

      # Verify service-1 is healthy
      {id1, health1} = Enum.find(results, fn {id, _} -> id == "service-1" end)
      assert id1 == "service-1"
      assert health1.status == :healthy

      # Verify service-2 is unhealthy
      {id2, health2} = Enum.find(results, fn {id, _} -> id == "service-2" end)
      assert id2 == "service-2"
      assert health2.status == :unhealthy
    end

    test "returns empty list for unregistered service type" do
      results = Health.check_all(:nonexistent_type)
      assert results == []
    end
  end

  describe "list_providers/0" do
    test "returns list of all registered provider types" do
      # Register some providers
      Health.register_provider(:provider_a, TestHealthProvider)
      Health.register_provider(:provider_b, TestHealthProvider)

      providers = Health.list_providers()

      assert is_list(providers)
      assert :provider_a in providers
      assert :provider_b in providers
    end
  end

  describe "health result structure" do
    setup do
      Health.register_provider(:test_service, TestHealthProvider)
      :ok
    end

    test "health result has all required fields" do
      {:ok, health} = Health.check_health(:test_service, "service-1")

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
