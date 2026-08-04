defmodule Mix.Tasks.Mydia.DeadCode do
  @moduledoc """
  Reports modules that no live code references.

  Force-compiles `lib/` and `test/` with a compiler tracer installed, builds the
  real module reference graph, and classifies every module as live, test-only,
  or orphaned. Because the compiler resolves aliases before the tracer sees
  them, an alias rename such as

      alias Mydia.Library.ReleaseParser, as: FileParser

  cannot disguise a dead module the way it does for grep.

  `test-only` is the interesting class: a module no production code calls but
  whose test suite still passes, reporting confidence about behaviour that never
  runs.

  ## Usage

      MIX_ENV=test mix mydia.dead_code
      MIX_ENV=test mix mydia.dead_code --format json

  This task is advisory. It does not fail the build unless `--exit-status` is
  passed.
  """
  use Mix.Task

  alias Mydia.DeadCode.Exemptions
  alias Mydia.DeadCode.Graph
  alias Mydia.DeadCode.Tracer

  @shortdoc "Reports modules no live code references"

  @switches [format: :string, exit_status: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    if Mix.env() != :test do
      Mix.raise("""
      mix mydia.dead_code must run with MIX_ENV=test.

      `test/support` is only on elixirc_paths in the test environment, so the
      test files cannot compile without it, and without them the analysis has
      no test edges and reports every test-only module as an orphan.

          MIX_ENV=test mix mydia.dead_code
      """)
    end

    # Load config only. Booting the supervision tree kills this task on an
    # unmigrated database via ClientHealth.init/1.
    Mix.Task.run("app.config")

    {result, definitions} = analyse()

    case Keyword.get(opts, :format, "text") do
      "text" ->
        print_text(result, definitions)

      "json" ->
        print_json(result, definitions)

      other ->
        Mix.raise("""
        mix mydia.dead_code: unknown --format #{inspect(other)}.

        Expected "text" or "json".
        """)
    end

    if Keyword.get(opts, :exit_status, false) and findings?(result, definitions) do
      exit({:shutdown, 1})
    end

    :ok
  end

  defp analyse do
    Tracer.start()
    Code.put_compiler_option(:tracers, [Tracer])

    try do
      compile_elixirc_paths()
      compile_test_files()

      definitions = Tracer.definitions()
      {Graph.classify(definitions, Tracer.edges(), &Exemptions.exempt?/1), definitions}
    after
      Code.put_compiler_option(:tracers, [])
      Tracer.stop()
    end
  end

  # By the time `run/1` starts, Mix has already compiled and loaded this
  # task's own module tree once (including Tracer itself), just to discover
  # "mydia.dead_code" as a task name. `Mix.Task.rerun("compile", ["--force"])`
  # cannot be used to recompile it a second time: `--force` (via
  # `Mix.Compilers.Elixir.compiler_info_from_force/4`) purges and
  # `:code.delete/1`s the *current* version of every module up front, before
  # a single file is recompiled, and only reloads each module once the
  # compiler gets around to its file. Tracer has no current version at all
  # for the whole compile up to that point, so the moment any other file
  # triggers a trace event first, the compiler calls the installed tracer
  # and gets `UndefinedFunctionError: module Mydia.DeadCode.Tracer is not
  # available`. This reproduced identically on every attempt, not as an
  # occasional fluke, because the gap is the entire compile, not an instant.
  #
  # Compiling directly through `Kernel.ParallelCompiler.compile_to_path/3`
  # avoids this: redefinition there goes through `:code.load_binary/3`,
  # which demotes the current version to old and installs the new one
  # atomically — there is no gap where Tracer has no current version, so no
  # exclusion list is needed and the detector can trace its own files too.
  # `max_concurrency: 1` is not what fixes the race (there isn't one to
  # serialize away under `load_binary`); it is kept as cheap, deliberate
  # insurance against any other self-referential surprise, not load-bearing
  # for this specific bug.
  #
  # This also means a second `mix mydia.dead_code` run inside the same BEAM
  # (e.g. from `iex -S mix` or a test) would hit the exact hazard this
  # avoids: Tracer's own file would still be "current" from the first run,
  # so recompiling it while it's the live, in-use tracer risks the same kind
  # of self-reference hazard `--force` has. Each invocation is expected to
  # run in its own fresh `mix mydia.dead_code` OS process.
  #
  # `elixirc_paths(:test)` is `["lib", "test/support"]`, not just `lib/`.
  # Hardcoding `lib/**/*.ex` would silently drop `test/support/**/*.ex` from
  # the traced set: `Graph.test_file?/1` matches on the "test/" prefix, so
  # edges originating there are what let a module referenced only from a
  # test fixture or helper land in `test_only` instead of `orphan`. Driving
  # the glob off `Mix.Project.config()[:elixirc_paths]` keeps this in sync
  # with whatever the project actually compiles under `MIX_ENV=test` rather
  # than a hardcoded guess that can drift from it.
  defp compile_elixirc_paths do
    files =
      Mix.Project.config()
      |> Keyword.fetch!(:elixirc_paths)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))

    dest = Mix.Project.compile_path()

    opts = [max_concurrency: 1, return_diagnostics: true]

    case Kernel.ParallelCompiler.compile_to_path(files, dest, opts) do
      {:ok, _modules, _warnings} ->
        :ok

      {:error, errors, _warnings} ->
        Mix.raise("mix mydia.dead_code: compile failed: #{inspect(errors)}")
    end
  end

  # `test/**/*_test.exs` is NOT on elixirc_paths and is never built by
  # `mix compile` — ExUnit loads those files at runtime. Without this second
  # pass there are no test edges at all, the `test_only` class is always empty,
  # and every test-only module misreports as an orphan.
  #
  # ExUnit must be started first because `use ExUnit.Case` executes at compile
  # time. `autorun: false` stops it running the suite we just loaded.
  defp compile_test_files do
    ExUnit.start(autorun: false)

    case Path.wildcard("test/**/*_test.exs") do
      [] ->
        :ok

      files ->
        case Kernel.ParallelCompiler.compile(files, return_diagnostics: true) do
          {:ok, _modules, _warnings} ->
            :ok

          {:error, errors, _warnings} ->
            Mix.raise("mix mydia.dead_code: test/ failed to compile: #{inspect(errors)}")
        end
    end
  end

  defp findings?(result, definitions) do
    lib_only(result.orphan, definitions) != [] or lib_only(result.test_only, definitions) != []
  end

  defp print_text(result, definitions) do
    orphan = lib_only(result.orphan, definitions)
    test_only = lib_only(result.test_only, definitions)

    Mix.shell().info("\nOrphaned modules (no references anywhere): #{length(orphan)}")
    Enum.each(orphan, &Mix.shell().info("  #{inspect(&1)}"))

    Mix.shell().info("\nTest-only modules (no lib/ callers): #{length(test_only)}")
    Enum.each(test_only, &Mix.shell().info("  #{inspect(&1)}"))

    Mix.shell().info("\nLive modules: #{length(result.live)}")
  end

  defp print_json(result, definitions) do
    %{
      orphan: result.orphan |> lib_only(definitions) |> Enum.map(&inspect/1),
      test_only: result.test_only |> lib_only(definitions) |> Enum.map(&inspect/1),
      live: Enum.map(result.live, &inspect/1),
      live_count: length(result.live)
    }
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end

  # `orphan` and `test_only` feed Task 5's deletion triage directly. Most raw
  # findings are test-file modules: a bare `XyzTest` module is structurally
  # unreachable (nothing ever calls a test module by name, so it always lands
  # in `orphan`), and test/support fixtures referenced only by other test
  # code land in `orphan` or `test_only` the same way. Neither is a deletion
  # candidate. Restricting both lists to modules actually defined under
  # `lib/` — per `definitions`, the map `Tracer.definitions/0` returned —
  # keeps the report scoped to what a human reviewing it can act on. `Graph`
  # itself is untouched: its classification is correct, this is filtering
  # what gets displayed from it.
  defp lib_only(modules, definitions) do
    Enum.filter(modules, fn mod -> String.starts_with?(Map.fetch!(definitions, mod), "lib/") end)
  end
end
