defmodule Mix.Tasks.Mydia.CardigannHealth do
  @moduledoc """
  Live compatibility sweep over Cardigann definitions.

  Each definition goes through the app's real path: mirror probe, a search with
  failover, an empty-query recheck when the probe query finds nothing, and a grab
  of the first row. Results land in one bucket each (see
  `Mydia.Indexers.Cardigann.LiveCheck.Outcome`).

  This talks to real trackers. It is a developer and operator tool and never runs
  in CI.

  ## Usage

      mix mydia.cardigann_health [options]

  ## Sources (default: enabled definitions in the database)

      --all               Every definition in the database
      --from-cache DIR    Every *.yml in DIR (for example the mydia.cardigann_compat cache)
      --upstream          Fetch the v11 definitions from GitHub

  ## Options

      --indexer ID        Only this indexer id
      --type TYPE         public, private, semi-private or all (default: all)
      --capture DIR       Write raw responses per definition under DIR (use tmp/cardigann_captures)
      --no-grab           Skip the grab leg
      --concurrency N     Parallel definitions (default: 8)
      --timeout MS        Per-definition timeout (default: 120000)
      --json              JSON output
  """

  use Mix.Task

  import Ecto.Query

  alias Mydia.Indexers.Cardigann.LiveCheck
  alias Mydia.Indexers.Cardigann.LiveCheck.Outcome
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.DefinitionSync
  alias Mydia.Repo

  @shortdoc "Live compatibility sweep over Cardigann definitions"

  @switches [
    all: :boolean,
    from_cache: :string,
    upstream: :boolean,
    indexer: :string,
    type: :string,
    capture: :string,
    grab: :boolean,
    concurrency: :integer,
    timeout: :integer,
    json: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    sources =
      opts
      |> load_sources()
      |> filter_type(Keyword.get(opts, :type, "all"))
      |> filter_indexer(opts[:indexer])

    if sources == [] do
      Mix.shell().info("No Cardigann indexer definitions found.")
      exit({:shutdown, 0})
    end

    unless opts[:json],
      do: Mix.shell().info("Testing #{length(sources)} Cardigann indexer(s)...\n")

    check_opts = [capture: opts[:capture], grab: Keyword.get(opts, :grab, true)]
    timeout = Keyword.get(opts, :timeout, 120_000)

    outcomes =
      sources
      |> Task.async_stream(
        fn {yaml, config} -> LiveCheck.check(yaml, Keyword.put(check_opts, :config, config)) end,
        max_concurrency: Keyword.get(opts, :concurrency, 8),
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(sources)
      |> Enum.map(fn
        {{:ok, outcome}, _} ->
          outcome

        {{:exit, reason}, {yaml, _}} ->
          %Outcome{
            id: yaml_id(yaml),
            bucket: :unreachable,
            error: "timed out: #{inspect(reason)}"
          }
      end)

    if opts[:json], do: print_json(outcomes), else: print_table(outcomes)
  end

  # Each source is {yaml, user_config}.
  defp load_sources(opts) do
    cond do
      dir = opts[:from_cache] ->
        dir
        |> Path.join("*.yml")
        |> Path.wildcard()
        |> Enum.map(&{File.read!(&1), %{}})

      opts[:upstream] ->
        {:ok, files} = DefinitionSync.list_definition_files()

        files
        |> Task.async_stream(&DefinitionSync.fetch_definition_file(&1["download_url"]),
          max_concurrency: 10,
          timeout: 60_000
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, yaml}} -> [{yaml, %{}}]
          _ -> []
        end)

      true ->
        CardigannDefinition
        |> then(fn q ->
          if opts[:all] || opts[:indexer], do: q, else: where(q, [d], d.enabled == true)
        end)
        |> Repo.all()
        |> Enum.map(&{&1.definition, &1.config || %{}})
    end
  end

  defp filter_type(sources, "all"), do: sources

  defp filter_type(sources, type) do
    Enum.filter(sources, fn {yaml, _} ->
      match?({:ok, %{"type" => ^type}}, YamlElixir.read_from_string(yaml))
    end)
  end

  defp filter_indexer(sources, nil), do: sources

  defp filter_indexer(sources, id),
    do: Enum.filter(sources, fn {yaml, _} -> yaml_id(yaml) == id end)

  defp yaml_id(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"id" => id}} -> id
      _ -> nil
    end
  end

  defp print_table(outcomes) do
    outcomes
    |> Enum.sort_by(&{to_string(&1.bucket), &1.id})
    |> Enum.each(fn o ->
      Mix.shell().info(
        "  #{String.pad_trailing(to_string(o.bucket), 16)} #{String.pad_trailing(o.id || "?", 24)} " <>
          "#{String.pad_leading(to_string(o.rows), 4)} rows  #{o.ms}ms  #{o.error || ""}"
      )
    end)

    Mix.shell().info("\n" <> String.duplicate("-", 60))

    outcomes
    |> Enum.frequencies_by(& &1.bucket)
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.each(fn {bucket, n} ->
      Mix.shell().info("  #{String.pad_trailing(to_string(bucket), 24)} #{n}")
    end)

    working = Enum.count(outcomes, &Outcome.working?/1)
    Mix.shell().info("\n  Working: #{working} of #{length(outcomes)}\n")
  end

  defp print_json(outcomes) do
    Mix.shell().info(
      Jason.encode!(
        %{
          total: length(outcomes),
          ok: Enum.count(outcomes, &Outcome.working?/1),
          failed: Enum.count(outcomes, &(not Outcome.working?(&1))),
          results:
            Enum.map(outcomes, fn o ->
              %{
                indexer_id: o.id,
                name: o.name,
                bucket: o.bucket,
                status: if(Outcome.working?(o), do: "ok", else: "error"),
                result_count: max(o.rows, o.rows_empty_query || 0),
                duration_ms: o.ms,
                base_url: o.base_url,
                grab: o.grab,
                error: o.error
              }
            end)
        },
        pretty: true
      )
    )
  end
end
