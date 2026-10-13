defmodule Mydia.Indexers.Cardigann.Wasm.EngineConfigTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Wasm.EngineConfig

  test "the runtime engine compiles serially for the host's own CPU" do
    config = EngineConfig.runtime_config()
    assert config.parallel_compilation == false
    assert config.isa_baseline == false
  end

  test "the CI engine compiles serially for the portable baseline and differs in nothing else" do
    assert EngineConfig.ci_config() ==
             %{EngineConfig.runtime_config() | isa_baseline: true}
  end

  test "the parallel compile can be switched back on" do
    Application.put_env(:mydia, :cardigann_wasm_parallel_compile, true)
    on_exit(fn -> Application.delete_env(:mydia, :cardigann_wasm_parallel_compile) end)
    assert EngineConfig.runtime_config().parallel_compilation == true
  end

  test "builds an engine from each config" do
    assert %Wasmex.Engine{} = Wasmex.Engine.new(EngineConfig.runtime_config()) |> elem(1)
    assert %Wasmex.Engine{} = Wasmex.Engine.new(EngineConfig.ci_config()) |> elem(1)
  end
end
