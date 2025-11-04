defmodule Mydia.Indexers.Adapter.RegistryTest do
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Adapter.{Error, Registry}
  alias Mydia.Indexers.SearchResult

  # Test adapter modules
  defmodule TestAdapter do
    @behaviour Mydia.Indexers.Adapter

    @impl true
    def test_connection(_config), do: {:ok, %{name: "Test Indexer", version: "1.0.0"}}

    @impl true
    def search(_config, _query, _opts),
      do:
        {:ok,
         [
           %SearchResult{
             title: "Test",
             size: 1000,
             seeders: 10,
             leechers: 5,
             download_url: "magnet:?",
             indexer: "test"
           }
         ]}

    @impl true
    def get_capabilities(_config) do
      {:ok,
       %{
         searching: %{
           search: %{available: true, supported_params: ["q"]}
         },
         categories: []
       }}
    end
  end

  defmodule AnotherTestAdapter do
    @behaviour Mydia.Indexers.Adapter

    @impl true
    def test_connection(_config), do: {:ok, %{name: "Another Indexer", version: "2.0.0"}}

    @impl true
    def search(_config, _query, _opts), do: {:ok, []}

    @impl true
    def get_capabilities(_config), do: {:ok, %{searching: %{}, categories: []}}
  end

  setup do
    # Clear registry before each test to ensure clean state
    Registry.clear()
    :ok
  end

  describe "register/2" do
    test "registers a new adapter" do
      assert :ok = Registry.register(:prowlarr, TestAdapter)
      assert Registry.registered?(:prowlarr)
    end

    test "allows registering multiple adapters" do
      assert :ok = Registry.register(:prowlarr, TestAdapter)
      assert :ok = Registry.register(:jackett, AnotherTestAdapter)

      assert Registry.registered?(:prowlarr)
      assert Registry.registered?(:jackett)
    end

    test "overwrites existing adapter with same type" do
      assert :ok = Registry.register(:prowlarr, TestAdapter)
      assert :ok = Registry.register(:prowlarr, AnotherTestAdapter)

      {:ok, adapter} = Registry.get_adapter(:prowlarr)
      assert adapter == AnotherTestAdapter
    end
  end

  describe "get_adapter/1" do
    test "returns adapter module when registered" do
      Registry.register(:prowlarr, TestAdapter)

      assert {:ok, TestAdapter} = Registry.get_adapter(:prowlarr)
    end

    test "returns error when adapter not registered" do
      assert {:error, %Error{type: :invalid_config}} = Registry.get_adapter(:unknown_indexer)
    end

    test "error includes indexer type in message" do
      {:error, error} = Registry.get_adapter(:unknown_indexer)

      assert error.message =~ "unknown_indexer"
      assert error.message =~ "Unknown indexer type"
    end
  end

  describe "get_adapter!/1" do
    test "returns adapter module when registered" do
      Registry.register(:prowlarr, TestAdapter)

      assert TestAdapter = Registry.get_adapter!(:prowlarr)
    end

    test "raises error when adapter not registered" do
      assert_raise Error, fn ->
        Registry.get_adapter!(:unknown_indexer)
      end
    end

    test "raised error includes helpful message" do
      error =
        assert_raise Error, fn ->
          Registry.get_adapter!(:unknown_indexer)
        end

      assert error.message =~ "unknown_indexer"
    end
  end

  describe "list_adapters/0" do
    test "returns empty list when no adapters registered" do
      assert [] = Registry.list_adapters()
    end

    test "returns all registered adapters" do
      Registry.register(:prowlarr, TestAdapter)
      Registry.register(:jackett, AnotherTestAdapter)

      adapters = Registry.list_adapters()

      assert length(adapters) == 2
      assert {:prowlarr, TestAdapter} in adapters
      assert {:jackett, AnotherTestAdapter} in adapters
    end
  end

  describe "registered?/1" do
    test "returns true when adapter is registered" do
      Registry.register(:prowlarr, TestAdapter)

      assert Registry.registered?(:prowlarr)
    end

    test "returns false when adapter is not registered" do
      refute Registry.registered?(:unknown_indexer)
    end
  end

  describe "unregister/1" do
    test "removes registered adapter" do
      Registry.register(:prowlarr, TestAdapter)
      assert Registry.registered?(:prowlarr)

      Registry.unregister(:prowlarr)

      refute Registry.registered?(:prowlarr)
    end

    test "does nothing when adapter not registered" do
      assert :ok = Registry.unregister(:unknown_indexer)
    end
  end

  describe "clear/0" do
    test "removes all registered adapters" do
      Registry.register(:prowlarr, TestAdapter)
      Registry.register(:jackett, AnotherTestAdapter)

      assert length(Registry.list_adapters()) == 2

      Registry.clear()

      assert [] = Registry.list_adapters()
    end
  end

  describe "integration with real adapters" do
    test "can dynamically select and use adapters" do
      Registry.register(:prowlarr, TestAdapter)
      Registry.register(:jackett, AnotherTestAdapter)

      config1 = %{type: :prowlarr, host: "localhost", port: 9696, api_key: "test"}
      config2 = %{type: :jackett, host: "localhost", port: 9117, api_key: "test"}

      {:ok, adapter1} = Registry.get_adapter(config1.type)
      {:ok, adapter2} = Registry.get_adapter(config2.type)

      assert {:ok, [%SearchResult{}]} = adapter1.search(config1, "test", [])
      assert {:ok, []} = adapter2.search(config2, "test", [])
    end
  end
end
