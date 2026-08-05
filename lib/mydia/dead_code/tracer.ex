defmodule Mydia.DeadCode.Tracer do
  @moduledoc """
  Compiler tracer that records which module is referenced from which file.

  Installed via `Code.put_compiler_option(:tracers, [__MODULE__])` by
  `Mix.Tasks.Mydia.DeadCode`. The compiler resolves aliases before invoking a
  tracer, so an alias rename such as

      alias Mydia.Library.ReleaseParser, as: FileParser

  is recorded against `Mydia.Library.ReleaseParser`, not against the local name.
  That is the property grep-based analysis lacks and the reason this module
  exists.

  `:alias_reference` counts as a real edge. Modules used as values rather than
  called (adapter and provider registration, for example) emit no
  `:remote_function` event at all. Counting alias references is safe here
  because `warnings_as_errors` rejects unused aliases, so a recorded alias
  reference implies genuine use.
  """

  @table :mydia_dead_code_edges

  @doc "Creates the collection table. Idempotent."
  @spec start() :: :ok
  def start do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    end

    :ok
  end

  @doc "Deletes the collection table. Idempotent."
  @spec stop() :: :ok
  def stop do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end

    :ok
  end

  @doc "Map of every traced module to the file that defines it."
  @spec definitions() :: %{module() => Path.t()}
  def definitions do
    @table
    |> :ets.match_object({:definition, :_, :_})
    |> Map.new(fn {:definition, module, file} -> {module, file} end)
  end

  @doc "List of `{callee_module, caller_file}` reference edges."
  @spec edges() :: [{module(), Path.t()}]
  def edges do
    @table
    |> :ets.match_object({:edge, :_, :_})
    |> Enum.map(fn {:edge, module, file} -> {module, file} end)
    |> Enum.uniq()
  end

  @doc false
  def trace({:on_module, _bytecode, _ignore}, env) do
    :ets.insert(@table, {:definition, env.module, relative(env.file)})
    :ok
  end

  def trace({:remote_function, _meta, module, _fun, _arity}, env), do: edge(module, env)
  def trace({:remote_macro, _meta, module, _fun, _arity}, env), do: edge(module, env)
  def trace({:imported_function, _meta, module, _fun, _arity}, env), do: edge(module, env)
  def trace({:imported_macro, _meta, module, _fun, _arity}, env), do: edge(module, env)
  def trace({:struct_expansion, _meta, module, _keys}, env), do: edge(module, env)
  def trace({:alias_reference, _meta, module}, env), do: edge(module, env)
  def trace(_event, _env), do: :ok

  defp edge(module, env) when is_atom(module) do
    :ets.insert(@table, {:edge, module, relative(env.file)})
    :ok
  end

  defp edge(_module, _env), do: :ok

  defp relative(nil), do: "unknown"

  defp relative(file) do
    Path.relative_to(file, File.cwd!())
  end
end
