defmodule Mydia.Indexers.Cardigann.Parity.Runner do
  @moduledoc """
  Records a live search through the wasm engine and replays a capture through
  both Cardigann engines.

  Recording writes `<out_dir>/<definition>/definition.yml` and the capture to
  `<out_dir>/<definition>/<kind>/`. Replay runs the wasm engine first, then the
  native one, each against its own fresh `Replay` and in its own unlinked task
  with a timeout, so a crash becomes an `{:error, ...}` outcome. The seam is
  installed inside that task.

  The wasm engine is the recorder, so it must find every request in the capture;
  a wasm miss is a harness bug and `compare/1` raises. A native miss is a real
  divergence (the engines build different URLs) and is reported as `:request`.
  """

  alias Mydia.Indexers.Adapter.Cardigann, as: ElixirAdapter
  alias Mydia.Indexers.Cardigann.Bench.Runner, as: Bench
  alias Mydia.Indexers.Cardigann.Parity.{Capture, Diff, Recorder, Replay, RequestKey, Seam}
  alias Mydia.Indexers.Cardigann.Wasm.Adapter, as: WasmAdapter

  @result_limit 1000
  @timeout_ms 130_000
  @wasm_timeout_ms 120_000
  @kinds %{"generic" => :generic, "movie" => :movie, "tv" => :tv, "rss" => :rss}

  @type outcome :: {:ok, [Mydia.Indexers.SearchResult.t()]} | {:error, term()}
  @type result :: %{
          capture: Capture.t(),
          native: outcome(),
          wasm: outcome(),
          misses: [RequestKey.t()],
          wasm_misses: [RequestKey.t()]
        }

  @doc "Upserts the definition row (enabled, in library) both engines read."
  @spec prepare_definition(String.t(), String.t()) :: :ok | {:error, term()}
  def prepare_definition(id, yaml) do
    Bench.prepare_row(%{id: id, yaml: yaml, settings: %{}})
  end

  @doc "Replays `capture` through the wasm engine, then the native one."
  @spec replay(Capture.t()) :: result()
  def replay(%Capture{} = capture) do
    {:ok, sup} = Task.Supervisor.start_link()

    try do
      {wasm, wasm_misses} = run_engine(sup, capture, &wasm_search/2)
      {native, misses} = run_engine(sup, capture, &native_search/2)

      %{capture: capture, native: native, wasm: wasm, misses: misses, wasm_misses: wasm_misses}
    after
      Supervisor.stop(sup)
    end
  end

  @doc "The `Diff` result for a `replay/1` result."
  @spec compare(result()) :: map()
  def compare(%{wasm_misses: [_ | _]}),
    do: raise(RuntimeError, "harness bug: wasm requested an unrecorded exchange")

  def compare(%{capture: capture} = result) do
    Diff.compare(
      capture.definition,
      capture.query.kind,
      result.native,
      result.wasm,
      result.misses
    )
  end

  @doc """
  Searches live through the wasm engine, recording every exchange. A capture is
  written whenever at least one exchange was made, including transport errors.
  """
  @spec record(map(), map(), Path.t(), keyword()) :: {:ok, Capture.t()} | {:error, term()}
  def record(definition, query, out_dir, opts \\ []) do
    with :ok <- Bench.prepare_row(definition) do
      {:ok, recorder} = Recorder.start_link()

      outcome =
        Seam.with(%{record: recorder}, fn ->
          WasmAdapter.search(Bench.adapter_config(definition), query.term,
            limit: @result_limit,
            timeout: @wasm_timeout_ms
          )
        end)

      write_capture(definition, query, out_dir, Recorder.exchanges(recorder), outcome, opts)
    end
  end

  defp write_capture(_definition, _query, _out_dir, [], outcome, _opts),
    do: {:error, {:no_exchanges, outcome}}

  defp write_capture(definition, query, out_dir, exchanges, _outcome, opts) do
    kind = Map.fetch!(@kinds, query.label)
    dir = Path.join(out_dir, definition.id)

    capture = %Capture{
      definition: definition.id,
      ref: Keyword.get(opts, :ref, "unknown"),
      query: %{kind: kind, term: query.term},
      exchanges: exchanges
    }

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "definition.yml"), definition.yaml)
    Capture.write!(capture, Path.join(dir, Atom.to_string(kind)))
    {:ok, capture}
  end

  # -- engines -------------------------------------------------------------------

  defp run_engine(sup, capture, search) do
    {:ok, replay} = Replay.start_link(capture)

    config =
      Bench.adapter_config(%{id: capture.definition, name: capture.definition, settings: %{}})

    task =
      Task.Supervisor.async_nolink(sup, fn ->
        try do
          Seam.with(%{replay: replay}, fn -> search.(config, capture.query.term) end)
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        catch
          kind, reason -> {:error, {kind, inspect(reason, limit: 8)}}
        end
      end)

    outcome =
      case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, outcome} -> outcome
        {:exit, reason} -> {:error, {:crash, inspect(reason, limit: 8)}}
        nil -> {:error, {:timeout, @timeout_ms}}
      end

    misses = Replay.misses(replay)
    Agent.stop(replay)
    {outcome, misses}
  end

  defp wasm_search(config, term),
    do: WasmAdapter.search(config, term, limit: @result_limit, timeout: @wasm_timeout_ms)

  defp native_search(config, term), do: ElixirAdapter.search(config, term, limit: @result_limit)
end
