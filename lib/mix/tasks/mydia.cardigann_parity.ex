defmodule Mix.Tasks.Mydia.CardigannParity do
  @moduledoc """
  Compares the native Elixir and the wasm Cardigann engines on recorded HTTP.

  `record` runs the wasm engine live against the real trackers and saves every
  HTTP exchange. `diff` replays those captures offline through both engines and
  reports where their results differ. This contacts real trackers with a few
  read-only searches per definition (`record` only).

  ## Usage

      ./dev mix mydia.cardigann_parity record --only linuxtracker
      ./dev mix mydia.cardigann_parity diff --only linuxtracker
      ./dev mix mydia.cardigann_parity diff --seed

  ## Options

      --ref REF         Prowlarr/Indexers commit to record from (record) or the
                        capture set to read (diff, default: the newest one)
      --only id,id      only these definition ids
      --cache DIR       cache root (default ~/.cache/mydia-cardigann-parity);
                        captures live in DIR/<ref>/<definition>/<kind>/
      --seed            diff the committed seed set instead of the cache
      --write-ratchet   diff: rewrite test/fixtures/cardigann/parity/known_divergences.exs
                        from what was found, keeping existing reasons

  `diff` writes `report.md` into the capture set (or prints it for `--seed`).
  `seed <definition>` is implemented by a later task.

  Like the benchmark, the task works on its own scratch SQLite database
  (`--database`, default under the cache root) and never touches the dev one.
  """

  use Mix.Task

  alias Mydia.Indexers.Cardigann.Bench.Corpus
  alias Mydia.Indexers.Cardigann.Parity.{Capture, Ratchet, Report, Runner}
  alias Mix.Tasks.Mydia.CardigannBench

  @shortdoc "Diffs the native and wasm Cardigann engines on recorded HTTP"

  @seed_dir "test/fixtures/cardigann/parity/seed"
  @ratchet_file "test/fixtures/cardigann/parity/known_divergences.exs"
  @switches [
    ref: :string,
    only: :string,
    cache: :string,
    seed: :boolean,
    write_ratchet: :boolean,
    database: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches)

    case rest do
      ["record"] -> record(opts)
      ["diff"] -> diff(opts)
      ["seed" | _] -> not_implemented("seed")
      _ -> Mix.raise("Usage: mix mydia.cardigann_parity record | diff | seed <definition>")
    end
  end

  defp not_implemented(command) do
    Mix.shell().error("mydia.cardigann_parity #{command}: not yet implemented")
    exit({:shutdown, 1})
  end

  # -- record -------------------------------------------------------------------

  defp record(opts) do
    root = cache_root(opts)
    start_app!(opts, root)

    corpus_opts =
      [cache_dir: root]
      |> put_opt(:ref, opts[:ref])
      |> put_opt(:only, only(opts))

    {definitions, meta} =
      case Corpus.load(corpus_opts) do
        {:ok, [_ | _] = defs, meta} -> {defs, meta}
        {:ok, [], _} -> Mix.raise("No definitions matched")
        {:error, reason} -> Mix.raise("Could not load the corpus: #{inspect(reason)}")
      end

    Mix.shell().info("Recording #{length(definitions)} definitions into #{meta.cache_dir}")

    for definition <- definitions, query <- definition.queries do
      File.rm_rf!(Path.join([meta.cache_dir, definition.id, query.label]))

      case Runner.record(definition, query, meta.cache_dir, ref: meta.ref) do
        {:ok, capture} ->
          Mix.shell().info(
            "#{definition.id}/#{query.label}: #{length(capture.exchanges)} exchanges"
          )

        {:error, reason} ->
          Mix.shell().error("#{definition.id}/#{query.label}: #{inspect(reason, limit: 5)}")
      end
    end

    :ok
  end

  # -- diff ---------------------------------------------------------------------

  defp diff(opts) do
    root = cache_root(opts)
    start_app!(opts, root)

    dir = if opts[:seed], do: @seed_dir, else: capture_set(root, opts[:ref])
    rows = dir |> captures(only(opts)) |> Enum.map(&compare/1)

    if rows == [], do: Mix.raise("No captures found in #{dir}")

    report = Report.render(rows)

    if opts[:seed] do
      Mix.shell().info(report)
    else
      path = Path.join(dir, "report.md")
      File.write!(path, report)
      Mix.shell().info(report <> "\nWrote #{path}")
    end

    if opts[:write_ratchet], do: write_ratchet(rows)
  end

  defp compare({capture, yaml}) do
    :ok = prepare!(capture.definition, yaml)
    result = capture |> Runner.replay() |> Runner.compare()
    Map.put(result, :definition, capture.definition) |> Map.put(:query, capture.query.kind)
  end

  defp prepare!(id, yaml) do
    case Runner.prepare_definition(id, yaml) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Could not load definition #{id}: #{inspect(reason)}")
    end
  end

  # `{capture, definition_yaml}` for every capture directory under `dir`.
  defp captures(dir, only) do
    for definition_dir <- Path.wildcard(Path.join(dir, "*")),
        File.regular?(Path.join(definition_dir, "definition.yml")),
        id = Path.basename(definition_dir),
        only == nil or id in only,
        yaml = File.read!(Path.join(definition_dir, "definition.yml")),
        exchanges <- Path.wildcard(Path.join(definition_dir, "*/exchanges.json")) do
      {Capture.read!(Path.dirname(exchanges)), yaml}
    end
  end

  defp write_ratchet(rows) do
    existing = if File.exists?(@ratchet_file), do: Ratchet.load!(@ratchet_file), else: []
    File.mkdir_p!(Path.dirname(@ratchet_file))
    File.write!(@ratchet_file, Ratchet.render(Enum.flat_map(rows, & &1.divergences), existing))
    Mix.shell().info("Wrote #{@ratchet_file}")
  end

  # -- shared -------------------------------------------------------------------

  defp cache_root(opts),
    do: Path.expand(opts[:cache] || "~/.cache/mydia-cardigann-parity")

  # The named ref, or the most recently written capture set under the root.
  defp capture_set(root, ref) when is_binary(ref), do: Path.join(root, ref)

  defp capture_set(root, nil) do
    sets = root |> Path.join("*") |> Path.wildcard() |> Enum.filter(&File.dir?/1)

    case Enum.sort_by(sets, &File.stat!(&1, time: :posix).mtime, :desc) do
      [newest | _] -> newest
      [] -> Mix.raise("No captures under #{root}; run record first")
    end
  end

  defp start_app!(opts, root) do
    database = Path.expand(opts[:database] || Path.join(root, "parity.db"))
    CardigannBench.isolate_database!(database)
    Mix.Task.run("app.start")
    CardigannBench.verify_database!(database)

    features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, Keyword.put(features, :cardigann_enabled, true))
    CardigannBench.ensure_engine!()
  end

  defp only(opts), do: opts[:only] && String.split(opts[:only], ",", trim: true)

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
