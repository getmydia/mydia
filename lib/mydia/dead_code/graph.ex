defmodule Mydia.DeadCode.Graph do
  @moduledoc """
  Turns raw tracer output into a dead-code classification.

  Liveness is forward reachability from exempt roots, grown to a fixpoint. A
  module is `live` when an exemption rule covers it (a framework entry point
  the compiler graph cannot see a call site for) or when a live `lib/` file
  references it. A file is live when any module it defines is live.

  A module no live file reaches is dead. If `test/` references it, it is
  `test_only`: the class that hides dead code behind a green suite, and the
  reason this tool exists. Otherwise it is an `orphan`.

  Direction matters. Defining liveness as "has an inbound edge" and then
  withdrawing edges from modules that lack one is unsound, because an entry
  point has no inbound edges by definition and the collapse cascades from the
  roots inward until everything is dead.

  Growing from roots also handles the case single-pass analysis cannot: a
  cluster whose members reference each other cites itself into looking alive
  under any inbound-edge rule, which is how a write-only island of a scanner,
  a context, and its schemas survives `mix_unused`. Under reachability it is
  simply never reached.
  """

  defmodule Result do
    @moduledoc "Classification output. Every list is sorted."
    defstruct live: [], test_only: [], orphan: []

    @type t :: %__MODULE__{
            live: [module()],
            test_only: [module()],
            orphan: [module()]
          }
  end

  @type definitions :: %{module() => Path.t()}
  @type edge :: {module(), Path.t()}

  @spec classify(definitions(), [edge()], (module() -> boolean())) :: Result.t()
  def classify(definitions, edges, exempt?) do
    # Index edges by the file that makes them, so expanding a live file is a
    # map lookup rather than a scan of every edge on each iteration.
    edges_by_caller =
      edges
      |> Enum.filter(fn {mod, file} -> lib_file?(file) and Map.has_key?(definitions, mod) end)
      |> Enum.group_by(fn {_mod, file} -> file end, fn {mod, _file} -> mod end)

    test_reached =
      for {mod, file} <- edges, test_file?(file), into: MapSet.new(), do: mod

    roots =
      definitions
      |> Map.keys()
      |> Enum.filter(exempt?)
      |> MapSet.new()

    live = reach(roots, definitions, edges_by_caller)

    definitions
    |> Map.keys()
    |> Enum.reduce(%Result{}, fn mod, acc ->
      cond do
        MapSet.member?(live, mod) -> %{acc | live: [mod | acc.live]}
        MapSet.member?(test_reached, mod) -> %{acc | test_only: [mod | acc.test_only]}
        true -> %{acc | orphan: [mod | acc.orphan]}
      end
    end)
    |> sort_result()
  end

  # Grow the live set until it stops growing. Monotone, so it always
  # terminates, and a reference cycle cannot loop it: a module already in the
  # set contributes nothing new on a later pass.
  defp reach(live, definitions, edges_by_caller) do
    next =
      live
      |> live_files(definitions)
      |> Enum.flat_map(&Map.get(edges_by_caller, &1, []))
      |> MapSet.new()
      |> MapSet.union(live)

    if MapSet.equal?(next, live), do: live, else: reach(next, definitions, edges_by_caller)
  end

  # A file is live when any module it defines is live.
  defp live_files(live, definitions) do
    for {mod, file} <- definitions, MapSet.member?(live, mod), into: MapSet.new(), do: file
  end

  defp sort_result(%Result{} = result) do
    %Result{
      live: Enum.sort(result.live),
      test_only: Enum.sort(result.test_only),
      orphan: Enum.sort(result.orphan)
    }
  end

  defp lib_file?(file), do: String.starts_with?(file, "lib/")
  defp test_file?(file), do: String.starts_with?(file, "test/")
end
