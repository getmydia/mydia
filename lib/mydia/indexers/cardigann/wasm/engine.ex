defmodule Mydia.Indexers.Cardigann.Wasm.Engine do
  @moduledoc """
  Runs Prowlarr's Cardigann engine, compiled to the wasip2 component described
  in `native/cardigann_guest/SPIKE.md`.

  The GenServer only owns the compiled component. Compiling the 75 MB guest
  costs about 3.3 s and happens once, asynchronously after boot, under one
  explicitly created `Wasmex.Engine`: a compiled component can be instantiated
  only in stores of the engine that compiled it. The engine and component sit
  in `:persistent_term`, and `call/3` runs in the caller's process: a fresh
  store and instance per call (about 3 ms), killed afterwards, so a hung or
  crashed guest never outlives its call.

  A missing or corrupt artifact is not an error at boot: `available?/0` is
  false and every call returns `:engine_unavailable`. A call that arrives while
  the guest is still compiling waits up to its own timeout for it.

  Each call emits `[:mydia, :cardigann, :wasm, :call]` with measurements
  `%{duration: native, network: native}` (`network` is the time spent inside
  host HTTP exchanges) and metadata `%{export: atom, outcome: atom}`.

  The `ctx` is `t:Mydia.Indexers.Cardigann.Wasm.HostHttp.ctx/0`. It may carry
  an `:indexer_name` (defaults to `definition_id`) used to label the releases.
  """

  use GenServer

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Codec, HostHttp}
  alias Wasmex.Components
  alias Wasmex.Wasi.WasiP2Options

  @type call ::
          {:capabilities, yaml :: String.t()}
          | {:search, String.t(), settings(), Codec.query(), Codec.session()}
          | {:download, String.t(), settings(), link :: String.t(), Codec.session()}
          | {:login, String.t(), settings(), Codec.session(), Codec.captcha_answer() | nil}
          | {:test, String.t(), settings(), Codec.session()}
  @type settings :: %{String.t() => String.t()}

  @interface "mydia:cardigann/engine@1.0.0"
  @memory_limit 512 * 1024 * 1024
  @key {__MODULE__, :compiled}

  # ── Client API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  True once the guest is compiled and callable. Never blocks on a compile that
  is already running. With `config :mydia, :cardigann_wasm_eager, false` (the
  test env) the compile starts on the first call to this or `call/3`, and this
  waits for it.
  """
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get(@key, nil) do
      nil -> ask(:available, 60_000) == {:ok, true}
      _compiled -> true
    end
  end

  @doc "Runs one engine call in a fresh, sandboxed instance."
  @spec call(call(), HostHttp.ctx(), pos_integer()) :: {:ok, term()} | {:error, Error.t()}
  def call(call, ctx, timeout_ms) do
    started = System.monotonic_time()
    export = elem(call, 0)

    case await(timeout_ms) do
      {:ok, compiled} ->
        remaining = max(timeout_ms - native_to_ms(System.monotonic_time() - started), 1)
        network = :atomics.new(2, signed: false)
        ctx = Map.put(ctx, :network, network)
        result = run(compiled, call, ctx, remaining)
        finish(export, ctx, started, network, result)

      :compiling ->
        error = Error.timeout("The Cardigann engine is still compiling", %{compiling: true})
        finish(export, ctx, started, nil, {:error, error})

      :unavailable ->
        finish(export, ctx, started, nil, {:error, unavailable()})
    end
  end

  defp await(timeout_ms) do
    case :persistent_term.get(@key, nil) do
      nil -> await_compile(timeout_ms)
      compiled -> {:ok, compiled}
    end
  end

  defp await_compile(timeout_ms) do
    case ask(:available, timeout_ms) do
      {:ok, true} ->
        if compiled = :persistent_term.get(@key, nil), do: {:ok, compiled}, else: :unavailable

      {:ok, false} ->
        :unavailable

      :timeout ->
        :compiling

      :down ->
        :unavailable
    end
  end

  # The server replies once the compile settles. Waiting out the caller's
  # patience is a timeout (the engine may yet become ready); a server that is
  # not running is unavailable.
  defp ask(message, timeout_ms) do
    {:ok, GenServer.call(__MODULE__, message, timeout_ms)}
  catch
    :exit, {:timeout, _} -> :timeout
    :exit, _ -> :down
  end

  defp unavailable do
    Error.engine_unavailable("The Cardigann engine is not available", %{
      hint: "run mix mydia.cardigann_guest fetch"
    })
  end

  # ── One call ──────────────────────────────────────────────────────────────

  # Re-lock the sandbox exactly as Mydia.Plugins.Host does: WasiP2Options
  # defaults inherit host stdio. The composed guest imports no wasi:http or
  # wasi:sockets (SPIKE.md "Sandbox lock"), so allow_http stays false.
  defp wasi do
    %WasiP2Options{
      inherit_stdin: false,
      inherit_stdout: false,
      inherit_stderr: false,
      allow_http: false
    }
  end

  defp run(%{engine: engine, component: component}, call, ctx, timeout_ms) do
    limits = %Wasmex.StoreLimits{memory_size: @memory_limit}

    with {:ok, store} <- Components.Store.new_wasi(wasi(), limits, engine),
         {:ok, pid} <-
           GenServer.start(Components, %{
             store: store,
             component: component,
             imports: HostHttp.imports(ctx)
           }) do
      try do
        invoke(pid, call, ctx, timeout_ms)
      after
        Process.exit(pid, :kill)
      end
    else
      {:error, reason} -> {:error, Error.engine_error("Instantiation failed: #{inspect(reason)}")}
    end
  end

  defp invoke(pid, call, ctx, timeout_ms) do
    {export, args} = encode(call)

    case Components.call_function(pid, [@interface, export], args, timeout_ms) do
      {:ok, {:ok, value}} -> {:ok, decode(call, value, ctx)}
      {:ok, {:error, engine_error}} -> {:error, Codec.decode_error(engine_error)}
      {:error, reason} -> {:error, trap_error(reason, timeout_ms)}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, Error.timeout("Cardigann call timed out after #{timeout_ms} ms")}

    :exit, reason ->
      {:error, Error.engine_error("Engine instance exited: #{inspect(reason)}")}
  end

  defp trap_error(reason, timeout_ms) do
    message = if is_binary(reason), do: reason, else: inspect(reason)

    if message =~ ~r/timed? ?out|deadline/i,
      do: Error.timeout("Cardigann call timed out after #{timeout_ms} ms"),
      else: Error.engine_error(message)
  end

  defp encode({:capabilities, yaml}), do: {"capabilities", [yaml]}

  defp encode({:search, yaml, settings, query, session}),
    do:
      {"search",
       [
         yaml,
         Codec.encode_settings(settings),
         Codec.encode_query(query),
         Codec.encode_session(session)
       ]}

  defp encode({:download, yaml, settings, link, session}),
    do: {"download", [yaml, Codec.encode_settings(settings), link, Codec.encode_session(session)]}

  defp encode({:login, yaml, settings, session, answer}),
    do:
      {"login",
       [
         yaml,
         Codec.encode_settings(settings),
         Codec.encode_session(session),
         Codec.encode_captcha_answer(answer)
       ]}

  defp encode({:test, yaml, settings, session}),
    do: {"test", [yaml, Codec.encode_settings(settings), Codec.encode_session(session)]}

  defp decode({:capabilities, _}, json, _ctx), do: Jason.decode!(json)

  defp decode({:search, _, _, _, _}, out, ctx),
    do: Codec.decode_search(out, Map.get(ctx, :indexer_name, ctx.definition_id))

  defp decode({:download, _, _, _, _}, out, _ctx), do: Codec.decode_download(out)
  defp decode({:login, _, _, _, _}, out, _ctx), do: Codec.decode_login(out)
  defp decode({:test, _, _, _}, session, _ctx), do: Codec.decode_session(session)

  # ── Telemetry ─────────────────────────────────────────────────────────────

  defp finish(export, ctx, started, network, result) do
    duration = System.monotonic_time() - started

    network_native =
      if network,
        do: System.convert_time_unit(:atomics.get(network, 1), :microsecond, :native),
        else: 0

    outcome = outcome(result)

    :telemetry.execute(
      [:mydia, :cardigann, :wasm, :call],
      %{duration: duration, network: network_native},
      %{export: export, outcome: outcome}
    )

    Logger.debug(
      "Cardigann wasm #{ctx.definition_id} #{export} #{outcome} in #{native_to_ms(duration)} ms"
    )

    result
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %Error{type: type}}), do: type

  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    :persistent_term.erase(@key)
    eager = Keyword.get(opts, :eager, Application.get_env(:mydia, :cardigann_wasm_eager, true))
    state = %{status: :pending, waiters: []}

    if eager,
      do: {:ok, %{state | status: :compiling}, {:continue, :compile}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:compile, state) do
    status = compile()
    for from <- state.waiters, do: GenServer.reply(from, status == :ready)
    {:noreply, %{state | status: status, waiters: []}}
  end

  @impl true
  def handle_call(:available, from, %{status: :pending} = state),
    do: {:noreply, %{state | status: :compiling, waiters: [from]}, {:continue, :compile}}

  def handle_call(:available, from, %{status: :compiling} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:available, _from, %{status: status} = state),
    do: {:reply, status == :ready, state}

  # Prefers the precompiled `<artifact>.cwasm` (mmapped, no Cranelift run) and
  # falls back to compiling the .wasm when it is absent or rejected: it is tied
  # to the wasmtime version, CPU architecture and engine config. Its own
  # function, so the 75 MB artifact binary is out of every frame afterwards.
  defp load_component(store) do
    with {:ok, bytes} <- Artifact.load() do
      cwasm = Artifact.path() <> ".cwasm"

      with true <- Application.get_env(:mydia, :cardigann_wasm_precompiled, true),
           true <- File.regular?(cwasm),
           {:ok, component} <- Components.Component.deserialize_file(store, cwasm, bytes) do
        {:ok, component, "loaded precompiled"}
      else
        _ ->
          with {:ok, component} <- Components.Component.new(store, bytes),
               do: {:ok, component, "compiled"}
      end
    end
  end

  # Compiling leaves about a GB of freed memory in glibc's arenas, which glibc
  # does not hand back by itself (native/cardigann_guest/BENCH.md, "Memory spike").
  defp release_build_memory do
    :erlang.garbage_collect()
    if Application.get_env(:mydia, :cardigann_wasm_trim, true), do: Wasmex.Engine.malloc_trim()
    :ok
  end

  defp compile do
    started = System.monotonic_time()
    # Test seam: lets a test observe a call that gives up while compiling.
    Process.sleep(Application.get_env(:mydia, :cardigann_wasm_compile_delay_ms, 0))

    with engine = Wasmex.Engine.default(),
         {:ok, store} <- Components.Store.new_wasi(wasi(), nil, engine),
         {:ok, component, how} <- load_component(store) do
      # The compile store stays referenced alongside the component.
      :persistent_term.put(@key, %{engine: engine, component: component, store: store})
      release_build_memory()

      Logger.info(
        "Cardigann wasm engine ready (#{how} in #{native_to_ms(System.monotonic_time() - started)} ms)"
      )

      :ready
    else
      {:error, reason} ->
        Logger.warning(
          "Cardigann wasm engine unavailable: #{inspect(reason)} " <>
            "(run mix mydia.cardigann_guest fetch)"
        )

        :unavailable
    end
  rescue
    e ->
      Logger.warning("Cardigann wasm engine failed to compile: #{Exception.message(e)}")
      :unavailable
  end
end
