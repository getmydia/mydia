defmodule Mydia.Indexers.CardigannEngineSelectionTest do
  # Mutates the environment, the :features config and the adapter registry.
  use ExUnit.Case, async: false

  alias Mydia.Indexers
  alias Mydia.Indexers.Adapter.Registry
  alias Mydia.Indexers.CardigannFeatureFlags
  alias Mydia.Indexers.Cardigann.Wasm

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  setup do
    features = Application.get_env(:mydia, :features, [])
    env = System.get_env("CARDIGANN_ENGINE")
    enable = System.get_env("ENABLE_CARDIGANN")

    on_exit(fn ->
      Application.put_env(:mydia, :features, features)
      restore("CARDIGANN_ENGINE", env)
      restore("ENABLE_CARDIGANN", enable)
      Indexers.register_adapters()
    end)

    :ok
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp put_features(overrides) do
    features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, Keyword.merge(features, overrides))
  end

  defp runtime_engine(value) do
    if value,
      do: System.put_env("CARDIGANN_ENGINE", value),
      else: System.delete_env("CARDIGANN_ENGINE")

    @runtime
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:mydia)
    |> Keyword.fetch!(:features)
    |> Keyword.fetch!(:cardigann_engine)
  end

  describe "CARDIGANN_ENGINE parsing in config/runtime.exs" do
    test "defaults to the built-in engine" do
      assert runtime_engine(nil) == :builtin
      assert runtime_engine("") == :builtin
    end

    test "accepts builtin and prowlarr" do
      assert runtime_engine("builtin") == :builtin
      assert runtime_engine("prowlarr") == :prowlarr
    end

    test "raises on any other value, naming the valid ones" do
      error = assert_raise RuntimeError, fn -> runtime_engine("wasm") end
      assert error.message =~ "builtin"
      assert error.message =~ "prowlarr"
      assert error.message =~ "wasm"
    end
  end

  test "the shipped default is the built-in engine" do
    assert :builtin ==
             Config.Reader.read!(Path.expand("config.exs", Path.dirname(@runtime)), env: :test)
             |> get_in([:mydia, :features, :cardigann_engine])
  end

  describe "adapter registry" do
    test "registers the Elixir adapter under :builtin" do
      put_features(cardigann_engine: :builtin)
      Indexers.register_adapters()

      assert {:ok, Mydia.Indexers.Adapter.Cardigann} = Registry.get_adapter(:cardigann)
    end

    test "registers the wasm adapter under :prowlarr" do
      put_features(cardigann_enabled: true, cardigann_engine: :prowlarr)
      Indexers.register_adapters()

      assert {:ok, Wasm.Adapter} = Registry.get_adapter(:cardigann)
    end

    test "keeps the Elixir adapter under :prowlarr when Cardigann is disabled" do
      put_features(cardigann_enabled: false, cardigann_engine: :prowlarr)
      Indexers.register_adapters()

      assert {:ok, Mydia.Indexers.Adapter.Cardigann} = Registry.get_adapter(:cardigann)
    end
  end

  describe "engine process" do
    test "is not among the application's children under :builtin" do
      put_features(cardigann_enabled: true, cardigann_engine: :builtin)
      refute Wasm.Engine in Mydia.Application.children()
    end

    test "is among them under :prowlarr" do
      put_features(cardigann_enabled: true, cardigann_engine: :prowlarr)
      assert Wasm.Engine in Mydia.Application.children()
    end

    test "is not started under :prowlarr when Cardigann is disabled" do
      put_features(cardigann_enabled: false, cardigann_engine: :prowlarr)
      refute Wasm.Engine in Mydia.Application.children()
    end

    test "is not running in the test application" do
      assert Process.whereis(Wasm.Engine) == nil
      assert Wasm.Engine.status() == :disabled
    end
  end

  describe "status" do
    test "reports the built-in engine as ready" do
      put_features(cardigann_engine: :builtin)
      assert %{engine: :builtin, state: :ready} = CardigannFeatureFlags.engine_status()
    end

    test "reports a selected but absent wasm engine as unavailable" do
      put_features(cardigann_engine: :prowlarr)

      assert %{engine: :prowlarr, state: :unavailable, detail: detail} =
               CardigannFeatureFlags.engine_status()

      assert detail =~ "not running"
    end

    test "a search against a stopped wasm engine names the reason" do
      # A wasm test that ran earlier in this VM can leave the compiled component
      # behind; a stopped engine has none.
      :persistent_term.erase({Wasm.Engine, :compiled})

      ctx = %{definition_id: "none", request_delay_ms: 0, flaresolverr: nil}
      empty = %{cookies: %{}, expires_at: nil}

      query = %{
        kind: :search,
        term: "x",
        categories: [],
        imdb_id: nil,
        tmdb_id: nil,
        tvdb_id: nil,
        season: nil,
        episode: nil,
        limit: nil,
        offset: nil
      }

      assert {:error, %{type: :engine_unavailable, message: message}} =
               Wasm.Engine.call({:search, "id: x", %{}, query, empty}, ctx, 1_000)

      assert message =~ "CARDIGANN_ENGINE=prowlarr"
    end
  end
end
