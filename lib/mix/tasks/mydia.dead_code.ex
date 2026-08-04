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

    result = analyse()

    case Keyword.get(opts, :format, "text") do
      "json" -> print_json(result)
      _ -> print_text(result)
    end

    if Keyword.get(opts, :exit_status, false) and findings?(result) do
      exit({:shutdown, 1})
    end

    :ok
  end

  defp analyse do
    Tracer.start()
    Code.put_compiler_option(:tracers, [Tracer])

    try do
      compile_lib_files()
      compile_test_files()

      Graph.classify(Tracer.definitions(), Tracer.edges(), &Exemptions.exempt?/1)
    after
      Code.put_compiler_option(:tracers, [])
      Tracer.stop()
    end
  end

  # By the time `run/1` starts, Mix has already compiled and loaded this
  # task's own module tree once (including Tracer itself), just to discover
  # "mydia.dead_code" as a task name. `Mix.Task.rerun("compile", ["--force"])`
  # would therefore recompile Tracer's own file while it is installed as the
  # active tracer for everything else: the compiler purges the old Tracer
  # module to load the freshly-compiled one, and a concurrently-compiling,
  # unrelated file can catch that gap and crash with `UndefinedFunctionError:
  # module Mydia.DeadCode.Tracer is not available`. This reproduced on every
  # attempt against this codebase, not as an occasional fluke.
  #
  # Compiling directly through Kernel.ParallelCompiler with max_concurrency: 1
  # serializes compilation so no two files are ever mid-compile at once,
  # which removes the race without excluding any file from the trace. This
  # bypasses the `:plugins` and `:phoenix_live_view` custom compiler stages,
  # but neither affects `.ex` module compilation itself: `:plugins` only
  # builds WASM build artifacts into priv/, and `:phoenix_live_view` only
  # extracts colocated JS/CSS to disk after the fact.
  defp compile_lib_files do
    files = Path.wildcard("lib/**/*.ex")
    dest = Mix.Project.compile_path()

    case Kernel.ParallelCompiler.compile_to_path(files, dest, max_concurrency: 1) do
      {:ok, _modules, _warnings} ->
        :ok

      {:error, errors, _warnings} ->
        Mix.raise("mix mydia.dead_code: lib/ failed to compile: #{inspect(errors)}")
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
      [] -> :ok
      files -> Kernel.ParallelCompiler.compile(files)
    end
  end

  defp findings?(result), do: result.orphan != [] or result.test_only != []

  defp print_text(result) do
    Mix.shell().info("\nOrphaned modules (no references anywhere): #{length(result.orphan)}")
    Enum.each(result.orphan, &Mix.shell().info("  #{inspect(&1)}"))

    Mix.shell().info("\nTest-only modules (no lib/ callers): #{length(result.test_only)}")
    Enum.each(result.test_only, &Mix.shell().info("  #{inspect(&1)}"))

    Mix.shell().info("\nLive modules: #{length(result.live)}")
  end

  defp print_json(result) do
    %{
      orphan: Enum.map(result.orphan, &inspect/1),
      test_only: Enum.map(result.test_only, &inspect/1),
      live_count: length(result.live)
    }
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end
end
