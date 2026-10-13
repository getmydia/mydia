defmodule Mydia.Indexers.Cardigann.Wasm.EngineConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Wasm.EngineConfig

  test "the runtime engine uses the Wasmex defaults" do
    assert EngineConfig.runtime_config() == %Wasmex.EngineConfig{}
  end

  test "the CI engine adds the portable baseline and differs in nothing else" do
    assert EngineConfig.ci_config() ==
             %{EngineConfig.runtime_config() | isa_baseline: true}
  end

  test "builds an engine from each config" do
    assert %Wasmex.Engine{} = Wasmex.Engine.new(EngineConfig.runtime_config()) |> elem(1)
    assert %Wasmex.Engine{} = Wasmex.Engine.new(EngineConfig.ci_config()) |> elem(1)
  end
end
