defmodule Mix.Tasks.Mydia.CardigannBench do
  @moduledoc """
  Benchmarks the Elixir and wasm Cardigann engines against Prowlarr.

  Each definition runs the same capability-matched query and the empty RSS query
  on Prowlarr (the oracle, in Docker), on `Mydia.Indexers.Adapter.Cardigann` and
  on `Mydia.Indexers.Cardigann.Wasm.Adapter`, back to back and in rotating order.
  The task writes `bench.json` and `bench.md` to `--out`.

  This contacts the real trackers with a few read-only searches per definition.

  ## Usage

      docker compose -f bench/cardigann/docker-compose.yml up -d
      ./dev mix mydia.cardigann_bench --limit 10 --out /tmp/bench-smoke

  ## Options

      --limit N            first N runnable definitions, in id order
      --only id,id         only these definition ids
      --credentials FILE   JSON {"<id>": {"username": "...", ...}} that adds
                           private definitions (keep the file outside the repo)
      --out DIR            output directory (default ~/.cache/mydia-cardigann-bench/out/<time>)
      --database PATH      bench SQLite file (default ~/.cache/mydia-cardigann-bench/bench.db)
      --prowlarr-url URL   default http://127.0.0.1:9696
      --prowlarr-api-key K default $PROWLARR_API_KEY, else bench/cardigann/data/config.xml
      --ref REF            Prowlarr/Indexers commit to pin (default: head of master)
      --cache-dir DIR      definition cache (default ~/.cache/mydia-cardigann-bench)
      --concurrency N      definitions run in parallel (default 4). Use 1 for the
                           gating run: parallel searches contend for CPU and the
                           database, which inflates the M4 overhead figures.

  ## Database isolation

  The task never touches the development database. Before the application
  starts it points `Mydia.Repo` at the `--database` file, runs the migrations on
  it, and refuses to continue if the Repo is not on that file. Only the SQLite
  adapter is supported. Oban queues and plugins are switched off for the run.
  """

  use Mix.Task

  alias Mydia.Indexers.Cardigann.Bench.{Corpus, Metrics, Oracle, Report, Runner}
  alias Mydia.Indexers.Cardigann.Wasm.Engine

  @shortdoc "Benchmarks the Cardigann engines against Prowlarr"

  @switches [
    limit: :integer,
    only: :string,
    credentials: :string,
    out: :string,
    database: :string,
    prowlarr_url: :string,
    prowlarr_api_key: :string,
    ref: :string,
    cache_dir: :string,
    concurrency: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)

    cache_dir = Path.expand(opts[:cache_dir] || Corpus.default_cache_dir())
    database = Path.expand(opts[:database] || Path.join(cache_dir, "bench.db"))
    out = Path.expand(opts[:out] || Path.join([cache_dir, "out", timestamp()]))

    api_key = fetch_api_key!(opts)
    credentials = read_credentials!(opts[:credentials])

    isolate_database!(database)
    Mix.Task.run("app.start")
    verify_database!(database)

    Mix.shell().info("Bench database: #{database}")

    ensure_engine!()
    {definitions, meta} = load_corpus!(opts, cache_dir, credentials)

    prowlarr_url = opts[:prowlarr_url] || "http://127.0.0.1:9696"
    oracle = Oracle.new(prowlarr_url, api_key, retry: false, receive_timeout: 58_000)

    Mix.shell().info(
      "Running #{length(definitions)} definitions (ref #{meta.ref}, #{length(meta.skipped)} left out)"
    )

    total = length(definitions)
    counter = :counters.new(1, [])

    results =
      Runner.run(definitions,
        oracle: oracle,
        concurrency: max(opts[:concurrency] || 4, 1),
        on_definition: fn {definition, rows} ->
          :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)

          Mix.shell().info(
            "[#{n}/#{total}] #{definition.id}: " <>
              Enum.map_join(rows, "; ", &summary/1)
          )
        end
      )

    metrics = Metrics.compute(results)
    meta = Map.merge(meta, %{database: database, prowlarr_url: prowlarr_url})
    {:ok, paths} = Report.write(metrics, results, meta, out)

    Mix.shell().info("Wrote #{paths.md}\nWrote #{paths.json}")
  end

  # The switcher starts the engine only when it is chosen; the bench starts it itself.
  defp ensure_engine! do
    :ok = Engine.ensure_started()

    unless Engine.available?() do
      Mix.raise(
        "The wasm engine is not available. Build and fetch the guest: " <>
          "native/cardigann_guest/build.sh wasm && ./dev mix mydia.cardigann_guest fetch"
      )
    end
  end

  defp load_corpus!(opts, cache_dir, credentials) do
    corpus_opts =
      [cache_dir: cache_dir, credentials: credentials]
      |> put_opt(:limit, opts[:limit])
      |> put_opt(:ref, opts[:ref])
      |> put_opt(:only, opts[:only] && String.split(opts[:only], ",", trim: true))

    {definitions, meta} =
      case Corpus.load(corpus_opts) do
        {:ok, defs, meta} -> {defs, meta}
        {:error, reason} -> Mix.raise("Could not load the corpus: #{inspect(reason)}")
      end

    if definitions == [], do: Mix.raise("The corpus is empty")
    {definitions, meta}
  end

  # -- database ---------------------------------------------------------------------

  defp isolate_database!(database) do
    Mix.Task.run("app.config")

    repo_config = Application.get_env(:mydia, Mydia.Repo, [])

    if Application.get_env(:mydia, :database_adapter) != Ecto.Adapters.SQLite3 do
      Mix.raise("mydia.cardigann_bench supports the SQLite adapter only (unset DATABASE_TYPE).")
    end

    File.mkdir_p!(Path.dirname(database))

    # Mydia.Application overlays the Repo's database path with the layered
    # runtime config, which reads DATABASE_PATH, so the Repo option alone is
    # not enough.
    System.put_env("DATABASE_PATH", database)

    Application.put_env(
      :mydia,
      Mydia.Repo,
      repo_config
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool_size, 10)
      |> Keyword.put(:busy_timeout, 30_000)
    )

    # Nothing in the bench needs background jobs, and the dev cron would sync
    # and probe on its own.
    oban = Application.get_env(:mydia, Oban, [])
    Application.put_env(:mydia, Oban, Keyword.merge(oban, queues: false, plugins: false))

    # Never migrate anything but the bench file.
    verify_database!(database)

    # The app skips migrations outside releases, so run them on the bench file.
    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mydia.Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true, log: false)
      end)
  end

  defp verify_database!(database) do
    configured = Mydia.Repo.config()[:database]

    if Path.expand(configured || "") != database do
      Mix.raise("Refusing to run: Mydia.Repo is on #{inspect(configured)}, not #{database}")
    end
  end

  # -- inputs -----------------------------------------------------------------------

  defp fetch_api_key!(opts) do
    key =
      opts[:prowlarr_api_key] || System.get_env("PROWLARR_API_KEY") || key_from_config_xml()

    case key do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        Mix.raise(
          "No Prowlarr API key. Start Prowlarr (docker compose -f bench/cardigann/docker-compose.yml up -d), " <>
            "then pass --prowlarr-api-key or set PROWLARR_API_KEY."
        )
    end
  end

  defp key_from_config_xml do
    with {:ok, xml} <- File.read("bench/cardigann/data/config.xml"),
         [_, key] <- Regex.run(~r{<ApiKey>([^<]+)</ApiKey>}, xml) do
      key
    else
      _ -> nil
    end
  end

  defp read_credentials!(nil), do: %{}

  defp read_credentials!(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = creds} <- Jason.decode(body) do
      creds
    else
      other -> Mix.raise("Could not read credentials from #{path}: #{inspect(other)}")
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp timestamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp summary(row) do
    counts =
      Enum.map_join([:prowlarr, :elixir, :wasm], "/", fn engine ->
        case row.engines[engine] do
          %{status: :ok, releases: releases} -> Integer.to_string(length(releases))
          %{status: {:error, kind}} -> "err:#{kind}"
        end
      end)

    "#{row.query}=#{counts}"
  end
end
