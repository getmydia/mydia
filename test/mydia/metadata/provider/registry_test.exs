defmodule Mydia.Metadata.Provider.RegistryTest do
  use ExUnit.Case, async: false

  alias Mydia.Metadata.Provider.{Error, Registry}
  alias Mydia.Metadata.Structs.ImagesResponse

  # Test provider modules
  defmodule TestProvider do
    @behaviour Mydia.Metadata.Provider

    alias Mydia.Metadata.Structs.ImagesResponse

    @impl true
    def test_connection(_config), do: {:ok, %{status: "ok", version: "3"}}

    @impl true
    def search(_config, _query, _opts), do: {:ok, []}

    @impl true
    def fetch_by_id(_config, _id, _opts), do: {:ok, %{}}

    @impl true
    def fetch_images(_config, _id, _opts),
      do: {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}

    @impl true
    def fetch_season(_config, _id, _season, _opts), do: {:ok, %{}}
  end

  defmodule AnotherTestProvider do
    @behaviour Mydia.Metadata.Provider

    alias Mydia.Metadata.Structs.ImagesResponse

    @impl true
    def test_connection(_config), do: {:ok, %{status: "ok", version: "4"}}

    @impl true
    def search(_config, _query, _opts), do: {:ok, []}

    @impl true
    def fetch_by_id(_config, _id, _opts), do: {:ok, %{}}

    @impl true
    def fetch_images(_config, _id, _opts),
      do: {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}

    @impl true
    def fetch_season(_config, _id, _season, _opts), do: {:ok, %{}}
  end

  setup do
    # Clear registry before each test to ensure clean state
    Registry.clear()
    :ok
  end

  describe "register/2" do
    test "registers a new provider" do
      assert :ok = Registry.register(:test_provider, TestProvider)
      assert Registry.registered?(:test_provider)
    end

    test "allows registering multiple providers" do
      assert :ok = Registry.register(:test_provider, TestProvider)
      assert :ok = Registry.register(:another_provider, AnotherTestProvider)

      assert Registry.registered?(:test_provider)
      assert Registry.registered?(:another_provider)
    end

    test "overwrites existing provider with same type" do
      assert :ok = Registry.register(:test_provider, TestProvider)
      assert :ok = Registry.register(:test_provider, AnotherTestProvider)

      {:ok, provider} = Registry.get_provider(:test_provider)
      assert provider == AnotherTestProvider
    end
  end

  describe "get_provider/1" do
    test "returns provider module when registered" do
      Registry.register(:test_provider, TestProvider)

      assert {:ok, TestProvider} = Registry.get_provider(:test_provider)
    end

    test "returns error when provider not registered" do
      assert {:error, %Error{type: :invalid_config}} =
               Registry.get_provider(:unknown_provider)
    end

    test "error includes provider type in message" do
      {:error, error} = Registry.get_provider(:unknown_provider)

      assert error.message =~ "unknown_provider"
      assert error.message =~ "Unknown provider type"
    end
  end

  describe "get_provider!/1" do
    test "returns provider module when registered" do
      Registry.register(:test_provider, TestProvider)

      assert TestProvider = Registry.get_provider!(:test_provider)
    end

    test "raises error when provider not registered" do
      assert_raise Error, fn ->
        Registry.get_provider!(:unknown_provider)
      end
    end

    test "raised error includes helpful message" do
      error =
        assert_raise Error, fn ->
          Registry.get_provider!(:unknown_provider)
        end

      assert error.message =~ "unknown_provider"
    end
  end

  describe "list_providers/0" do
    test "returns empty list when no providers registered" do
      assert [] = Registry.list_providers()
    end

    test "returns all registered providers" do
      Registry.register(:test_provider, TestProvider)
      Registry.register(:another_provider, AnotherTestProvider)

      providers = Registry.list_providers()

      assert length(providers) == 2
      assert {:test_provider, TestProvider} in providers
      assert {:another_provider, AnotherTestProvider} in providers
    end
  end

  describe "registered?/1" do
    test "returns true when provider is registered" do
      Registry.register(:test_provider, TestProvider)

      assert Registry.registered?(:test_provider)
    end

    test "returns false when provider is not registered" do
      refute Registry.registered?(:unknown_provider)
    end
  end

  describe "unregister/1" do
    test "removes registered provider" do
      Registry.register(:test_provider, TestProvider)
      assert Registry.registered?(:test_provider)

      Registry.unregister(:test_provider)

      refute Registry.registered?(:test_provider)
    end

    test "does nothing when provider not registered" do
      assert :ok = Registry.unregister(:unknown_provider)
    end
  end

  describe "clear/0" do
    test "removes all registered providers" do
      Registry.register(:test_provider, TestProvider)
      Registry.register(:another_provider, AnotherTestProvider)

      assert length(Registry.list_providers()) == 2

      Registry.clear()

      assert [] = Registry.list_providers()
    end
  end

  describe "integration with real providers" do
    test "can dynamically select and use providers" do
      Registry.register(:test_provider, TestProvider)
      Registry.register(:another_provider, AnotherTestProvider)

      config1 = %{type: :test_provider, api_key: "key1", base_url: "https://api1.example.com"}
      config2 = %{type: :another_provider, api_key: "key2", base_url: "https://api2.example.com"}

      {:ok, provider1} = Registry.get_provider(config1.type)
      {:ok, provider2} = Registry.get_provider(config2.type)

      assert {:ok, []} = provider1.search(config1, "The Matrix", [])
      assert {:ok, []} = provider2.search(config2, "Breaking Bad", [])
    end
  end
end
