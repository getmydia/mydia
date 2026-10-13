defmodule Mydia.Indexers.Cardigann.Wasm.EngineConfig do
  @moduledoc """
  The Wasmex engine configurations for the Cardigann guest, in one place, because
  a precompiled `.cwasm` loads only into an engine whose config matches the one
  that wrote it.

    * `runtime_config/0`: what `Mydia.Indexers.Cardigann.Wasm.Engine` compiles,
      deserializes and instantiates with. Host CPU features; serial Cranelift by
      default, because a parallel compile of the 39 MB guest peaks at about
      1.5 GB (`native/cardigann_guest/BENCH.md`). Serial costs nothing after the
      compile.
    * `ci_config/0`: the same with a portable ISA baseline, for the `.cwasm`
      that CI publishes (`native/cardigann_guest/scripts/precompile.exs`).

  This module depends on Wasmex only: the CI script loads it with
  `Code.require_file/1` outside the application. Changing either config means
  bumping `@cwasm_config_version` in `Mydia.Indexers.Cardigann.Wasm.Artifact`.
  """

  @key {__MODULE__, :runtime_engine}

  @spec runtime_config() :: Wasmex.EngineConfig.t()
  def runtime_config do
    %Wasmex.EngineConfig{}
    |> Wasmex.EngineConfig.parallel_compilation(
      Application.get_env(:mydia, :cardigann_wasm_parallel_compile, false)
    )
  end

  @spec ci_config() :: Wasmex.EngineConfig.t()
  def ci_config, do: Wasmex.EngineConfig.isa_baseline(runtime_config(), true)

  @doc "The runtime engine, created once per VM."
  @spec runtime_engine() :: Wasmex.Engine.t()
  def runtime_engine do
    case :persistent_term.get(@key, nil) do
      nil ->
        {:ok, engine} = Wasmex.Engine.new(runtime_config())
        :persistent_term.put(@key, engine)
        engine

      engine ->
        engine
    end
  end

  @spec ci_engine() :: Wasmex.Engine.t()
  def ci_engine do
    {:ok, engine} = Wasmex.Engine.new(ci_config())
    engine
  end
end
