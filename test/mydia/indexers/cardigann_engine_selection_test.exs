defmodule Mydia.Indexers.CardigannEngineSelectionTest do
  # Mutates the environment, the :features config and the adapter registry.
  use ExUnit.Case, async: false

  alias Mydia.Indexers
  alias Mydia.Indexers.Cardigann.Wasm

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

  describe "engine process" do
    test "is not running in the test application" do
      assert Process.whereis(Wasm.Engine) == nil
      assert Wasm.Engine.status() == :disabled
    end
  end

  describe "status" do
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
