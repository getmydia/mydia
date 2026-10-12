defmodule Mydia.Indexers.Cardigann.Bench.Runner do
  @moduledoc """
  Runs the three engines (Prowlarr, the Elixir Cardigann engine, the wasm
  engine) over a corpus and returns one row per definition and query.

  For each definition the `CardigannDefinition` row is upserted into the
  database the Repo points at (the task points it at a bench-only file), then
  every query runs the engines back to back, one after another, in an order
  rotated by the definition's position so tracker drift and rate limits hit all
  three alike. Up to `:concurrency` definitions run in parallel.

  Each engine call runs in its own unlinked task with a hard timeout. A crash or
  timeout is recorded as that engine's result and never stops the run.

  Row shape (see `Mydia.Indexers.Cardigann.Bench.Metrics`):

      %{id, name, type, query, term, request_delay_ms,
        engines: %{prowlarr: result, elixir: result, wasm: result}}

  A result is `%{status, releases, wall_ms, network_ms, empty_with_credentials,
  error}`. `network_ms` is nil for Prowlarr, whose internals are not observable.
  For the Elixir engine it is the time inside `Req.Finch` (`NetTimer`); for wasm
  it is the host `http-request` time from the engine's telemetry.

  `empty_with_credentials` is true when a private definition with configured
  credentials returned `{:ok, []}`. Prowlarr and the wasm engine swallow a failed
  login during search and return no results, so this is kept apart from a plain
  empty result and counted in the report.
  """

  alias Mydia.Indexers.Adapter.Cardigann, as: ElixirAdapter
  alias Mydia.Indexers.Cardigann.Bench.{NetTimer, Oracle, Release}
  alias Mydia.Indexers.Cardigann.Wasm.Adapter, as: WasmAdapter
  alias Mydia.Indexers.{CardigannDefinition, DefinitionSync}
  alias Mydia.Repo

  @engines [:prowlarr, :elixir, :wasm]
  @call_timeout_ms 60_000
  @wasm_timeout_ms 55_000
  @result_limit 1000
  @telemetry_id "mydia-cardigann-bench-wasm-network"
  @wasm_event [:mydia, :cardigann, :wasm, :call]

  @type result :: map()

  @doc """
  Runs `definitions` (from `Corpus.load/1`). Options: `:oracle` (an `Oracle`),
  `:concurrency` (default 4), `:on_definition` (a 1-arity progress callback).
  """
  @spec run([map()], keyword()) :: [map()]
  def run(definitions, opts) do
    oracle = Keyword.fetch!(opts, :oracle)
    concurrency = Keyword.get(opts, :concurrency, 4)
    progress = Keyword.get(opts, :on_definition, fn _ -> :ok end)

    NetTimer.init()
    previous_flags = enable_cardigann_feature()
    previous_req = install_net_timer()
    attach_wasm_telemetry()
    {:ok, sup} = Task.Supervisor.start_link()

    try do
      definitions
      |> Enum.with_index()
      |> Task.async_stream(
        fn {definition, index} ->
          rows = run_definition(definition, index, oracle, sup)
          progress.({definition, rows})
          rows
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.flat_map(fn {:ok, rows} -> rows end)
    after
      :telemetry.detach(@telemetry_id)
      Req.default_options(previous_req)
      Application.put_env(:mydia, :features, previous_flags)
    end
  end

  @doc "Engines in the order they run for the definition at `index`."
  @spec rotation(non_neg_integer()) :: [atom()]
  def rotation(index) do
    shift = rem(index, length(@engines))
    Enum.drop(@engines, shift) ++ Enum.take(@engines, shift)
  end

  @doc """
  True for a private or semi-private definition with credentials configured whose
  engine returned `{:ok, []}`.
  """
  @spec empty_with_credentials?(map(), atom(), [Release.t()]) :: boolean()
  def empty_with_credentials?(definition, status, releases) do
    status == :ok and releases == [] and definition.type != "public" and
      definition.credentials? == true
  end

  # -- definition --------------------------------------------------------------

  defp run_definition(definition, index, oracle, sup) do
    delay = request_delay_ms(definition.yaml)

    local = prepare_row(definition)
    prowlarr_id = ensure_prowlarr(oracle, definition)

    for query <- definition.queries do
      engines =
        Enum.reduce(rotation(index), %{}, fn engine, acc ->
          result =
            case {engine, local, prowlarr_id} do
              {:prowlarr, _, {:ok, id}} ->
                timed(sup, definition, :prowlarr, fn -> prowlarr_search(oracle, id, query) end)

              {:prowlarr, _, {:error, reason}} ->
                error_result({:indexer, reason})

              {_, {:error, reason}, _} ->
                error_result({:local_definition, reason})

              {:elixir, :ok, _} ->
                timed(sup, definition, :elixir, fn -> elixir_search(definition, query) end)

              {:wasm, :ok, _} ->
                timed(sup, definition, :wasm, fn -> wasm_search(definition, query) end)
            end

          Map.put(acc, engine, result)
        end)

      %{
        id: definition.id,
        name: definition.name,
        type: definition.type,
        query: query.label,
        term: query.term,
        request_delay_ms: delay,
        engines: engines
      }
    end
  end

  defp request_delay_ms(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = doc} -> WasmAdapter.request_delay_ms(doc["requestDelay"] || doc["requestdelay"])
      _ -> 0
    end
  end

  # -- local database ------------------------------------------------------------

  defp prepare_row(definition) do
    with {:ok, attrs} <- DefinitionSync.parse_definition(definition.yaml, definition.id),
         attrs = Map.put(attrs, :indexer_id, definition.id),
         {:ok, _action, row} <- DefinitionSync.upsert_definition(attrs) do
      row
      |> Ecto.Changeset.change(%{
        in_library: true,
        enabled: true,
        config: definition.settings,
        active_link: nil
      })
      |> Repo.update()
      |> case do
        {:ok, %CardigannDefinition{}} -> :ok
        {:error, changeset} -> {:error, {:update, changeset.errors}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp adapter_config(definition) do
    %{
      type: :cardigann,
      name: definition.name,
      indexer_id: definition.id,
      enabled: true,
      user_settings: definition.settings
    }
  end

  # -- engines --------------------------------------------------------------------

  defp ensure_prowlarr(oracle, definition) do
    Oracle.ensure_indexer(oracle, definition.id, definition.settings)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp prowlarr_search(oracle, indexer_id, query) do
    case Oracle.search(oracle, indexer_id, Map.put(query, :limit, @result_limit)) do
      {:ok, releases} -> {:ok, releases, nil}
      {:error, reason} -> {:error, {:prowlarr, summarize(reason)}}
    end
  end

  defp elixir_search(definition, query) do
    finish_adapter(
      ElixirAdapter.search(adapter_config(definition), query.term, limit: @result_limit),
      :elixir
    )
  end

  defp wasm_search(definition, query) do
    finish_adapter(
      WasmAdapter.search(adapter_config(definition), query.term,
        limit: @result_limit,
        timeout: @wasm_timeout_ms
      ),
      :wasm
    )
  end

  defp finish_adapter({:ok, results}, _engine),
    do: {:ok, Enum.map(results, &Release.from_search_result/1), nil}

  defp finish_adapter({:error, %{type: type} = error}, _engine),
    do: {:error, {type, summarize(Map.get(error, :message))}}

  defp finish_adapter({:error, other}, _engine), do: {:error, {:other, summarize(other)}}

  # Calls `fun` in an unlinked task with a hard timeout. The task registers for
  # network timing, and the wasm telemetry handler (which runs in the process
  # that calls the engine, this task) accumulates into its process dictionary.
  defp timed(sup, definition, engine, fun) do
    task =
      Task.Supervisor.async_nolink(sup, fn ->
        counter = NetTimer.register()
        Process.put(:bench_wasm_network_ms, 0.0)
        started = System.monotonic_time()

        outcome =
          try do
            fun.()
          rescue
            e -> {:error, {:exception, summarize(Exception.message(e))}}
          catch
            kind, reason -> {:error, {kind, summarize(reason)}}
          end

        wall_ms =
          System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) /
            1000

        network_ms =
          case engine do
            :elixir -> NetTimer.read_ms(counter)
            :wasm -> Process.get(:bench_wasm_network_ms, 0.0)
            :prowlarr -> nil
          end

        NetTimer.unregister()
        {outcome, wall_ms, network_ms}
      end)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {outcome, wall_ms, network_ms}} ->
        build_result(definition, outcome, wall_ms, network_ms)

      {:exit, reason} ->
        error_result({:crash, summarize(reason)})

      nil ->
        %{error_result({:timeout, @call_timeout_ms}) | wall_ms: @call_timeout_ms * 1.0}
    end
  end

  defp build_result(definition, {:ok, releases, _}, wall_ms, network_ms) do
    %{
      status: :ok,
      releases: releases,
      wall_ms: wall_ms,
      network_ms: network_ms,
      empty_with_credentials: empty_with_credentials?(definition, :ok, releases),
      error: nil
    }
  end

  defp build_result(_definition, {:error, reason}, wall_ms, network_ms) do
    %{error_result(reason) | wall_ms: wall_ms, network_ms: network_ms}
  end

  defp error_result(reason) do
    %{
      status: {:error, error_kind(reason)},
      releases: [],
      wall_ms: nil,
      network_ms: nil,
      empty_with_credentials: false,
      error: summarize(reason)
    }
  end

  defp error_kind({kind, _detail}) when is_atom(kind), do: kind
  defp error_kind(kind) when is_atom(kind), do: kind
  defp error_kind(_), do: :unknown

  # Error text can carry URLs; keep it short. Credentials are never part of the
  # engines' error messages, and request bodies are not included here.
  defp summarize(term) do
    text = if is_binary(term), do: term, else: inspect(term, limit: 8, printable_limit: 200)
    String.slice(text, 0, 300)
  end

  # -- run-wide state ----------------------------------------------------------------

  defp enable_cardigann_feature do
    previous = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, Keyword.put(previous, :cardigann_enabled, true))
    previous
  end

  defp install_net_timer do
    previous = Req.default_options()
    Req.default_options(Keyword.put(previous, :adapter, NetTimer))
    previous
  end

  defp attach_wasm_telemetry do
    :telemetry.detach(@telemetry_id)
    :telemetry.attach(@telemetry_id, @wasm_event, &__MODULE__.handle_wasm_call/4, nil)
  end

  @doc false
  # Runs in the process that called `Engine.call/3`, so the process dictionary
  # is the task's. Only the search export counts toward the search's network time.
  def handle_wasm_call(_event, measurements, %{export: :search}, _config) do
    ms = System.convert_time_unit(measurements.network, :native, :microsecond) / 1000
    Process.put(:bench_wasm_network_ms, Process.get(:bench_wasm_network_ms, 0.0) + ms)
    :ok
  end

  def handle_wasm_call(_event, _measurements, _metadata, _config), do: :ok
end
