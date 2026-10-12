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
  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Codec, Delivery, HostHttp}
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

  @doc """
  Starts the engine under the application supervisor when it is not running.

  The application starts it only for `CARDIGANN_ENGINE=prowlarr`; the bench task
  and the engine tests use this to run it regardless.
  """
  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case Supervisor.start_child(Mydia.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart()
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart do
    case Supervisor.restart_child(Mydia.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The engine's state, without waiting: `:disabled` (not selected, so the process
  does not run), `:pending`, `:fetching` (downloading the artifact),
  `:compiling` (compiling or loading it), `:ready`, or `{:unavailable, reason}`
  with a printable reason.
  """
  @spec status() ::
          :disabled | :pending | :fetching | :compiling | :ready | {:unavailable, String.t()}
  def status do
    GenServer.call(__MODULE__, :status, 1_000)
  catch
    # No process: the engine was not selected. A busy one is still starting.
    :exit, {:timeout, _} -> :compiling
    :exit, _ -> :disabled
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
        finish(export, ctx, started, nil, {:error, unavailable(status())})
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

  defp unavailable(:disabled) do
    Error.engine_unavailable(
      "The Prowlarr Cardigann engine is not running: set CARDIGANN_ENGINE=prowlarr to enable it",
      %{reason: :disabled}
    )
  end

  defp unavailable({:unavailable, reason}) do
    Error.engine_unavailable(
      "The Prowlarr Cardigann engine is not available: #{reason}",
      %{reason: reason}
    )
  end

  defp unavailable(_other) do
    Error.engine_unavailable("The Prowlarr Cardigann engine is not available")
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
    # Trapping exits makes a supervisor shutdown run terminate/2, which drops the
    # compiled component: a stopped engine serves nothing.
    Process.flag(:trap_exit, true)
    :persistent_term.erase(@key)
    eager = Keyword.get(opts, :eager, Application.get_env(:mydia, :cardigann_wasm_eager, true))
    state = %{status: :pending, waiters: [], task: nil, failures: 0, timer: nil, last_reason: nil}

    if eager,
      do: {:ok, %{state | status: :compiling}, {:continue, :compile}},
      else: {:ok, state}
  end

  # The compile (several seconds) runs in its own process, so the server keeps
  # answering status/0 and queueing waiters while it works. The process is
  # monitored, not linked: a compile that raises or exits settles the engine as
  # unavailable instead of taking the server (and, through restarts, the
  # supervisor) down with it.
  @impl true
  def handle_continue(:compile, state) do
    fun = Application.get_env(:mydia, :cardigann_wasm_compile_fun, &compile/0)
    server = self()
    task = spawn_monitor(fn -> send(server, {:compiled, self(), fun.()}) end)
    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_info({:compiled, pid, status}, %{task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(state, status)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {_pid2, ref}} = state),
    do: {:noreply, settle(state, {:unavailable, "compile crashed: #{inspect(reason)}"})}

  # The background process reports which step it is on (download, then compile
  # or load), for the status line. A late message after the settle is ignored.
  def handle_info({:phase, phase}, %{status: status} = state)
      when status in [:compiling, :fetching],
      do: {:noreply, %{state | status: phase}}

  def handle_info(:retry, %{status: {:unavailable, _}} = state),
    do: {:noreply, %{state | status: :compiling, timer: nil}, {:continue, :compile}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@key)
    :ok
  end

  # A failed fetch or compile is tried again in the background, 30 s after the
  # first failure, doubling up to 30 minutes, until it works. A result tagged
  # :permanent (a checksum mismatch, a build without a pin) cannot change by
  # waiting and is not retried. The status names when the next attempt is due.
  @retry_cap_ms 30 * 60 * 1000

  defp settle(state, status) do
    for from <- state.waiters, do: GenServer.reply(from, status == :ready)
    state = %{state | waiters: [], task: nil}

    case status do
      :ready ->
        %{state | status: :ready, failures: 0}

      {:unavailable, reason, :permanent} ->
        %{state | status: {:unavailable, reason}}

      {:unavailable, reason} ->
        delay = retry_delay(state.failures)

        due =
          DateTime.utc_now() |> DateTime.add(delay, :millisecond) |> DateTime.truncate(:second)

        %{
          state
          | status: {:unavailable, "#{reason} (next attempt #{DateTime.to_iso8601(due)})"},
            failures: state.failures + 1,
            last_reason: reason,
            timer: Process.send_after(self(), :retry, delay)
        }
    end
  end

  defp retry_delay(failures) do
    base = Application.get_env(:mydia, :cardigann_wasm_retry_ms, 30_000)
    min(base * Integer.pow(2, failures), max(@retry_cap_ms, base))
  end

  @impl true
  # During a background retry the engine is still unavailable: say so, and say why.
  def handle_call(:status, _from, %{failures: failures, status: status} = state)
      when failures > 0 and status in [:compiling, :fetching],
      do: {:reply, {:unavailable, "#{state.last_reason} (retrying now)"}, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  # A caller does not wait out a retry: the last attempt failed, so it gets the
  # unavailable answer at once rather than after its whole timeout.
  def handle_call(:available, _from, %{failures: failures, status: status} = state)
      when failures > 0 and status in [:compiling, :fetching],
      do: {:reply, false, state}

  def handle_call(:available, from, %{status: :pending} = state),
    do: {:noreply, %{state | status: :compiling, waiters: [from]}, {:continue, :compile}}

  def handle_call(:available, from, %{status: status} = state)
      when status in [:compiling, :fetching],
      do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:available, _from, %{status: status} = state),
    do: {:reply, status == :ready, state}

  # Resolves and loads the component. The precompiled
  # `cardigann-<hash>-wasmtime<version>-<arch>.cwasm` is mmapped and skips the
  # Cranelift run; it is tied to the wasmtime version, CPU features and engine
  # config, so a file that is rejected is deleted and rebuilt. Without one the
  # .wasm is compiled once, serialized atomically next to it, and the
  # serialized form is what gets loaded (about 65 MB less resident than the
  # freshly compiled component, BENCH.md "Memory spike"). Its own function, so
  # the 75 MB artifact binary is out of every frame afterwards.
  defp load_component(store) do
    send_phase(:fetching)

    with {:ok, _path, bytes} <- Delivery.ensure() do
      send_phase(:compiling)
      sha = Artifact.sha256(bytes)
      cwasm = Artifact.cwasm_path(sha)

      result =
        if precompiled?(),
          do: load_cached(store, cwasm, bytes) || build_cached(store, cwasm, bytes),
          else: nil

      case result || compile_component(store, bytes) do
        {:ok, component, how} ->
          Delivery.prune(Artifact.cache_dir(), sha)
          {:ok, component, how}

        {:error, _} = error ->
          error
      end
    end
  end

  defp precompiled?, do: Application.get_env(:mydia, :cardigann_wasm_precompiled, true)

  # The precompiled component is native code that wasmtime maps without
  # checking, so it is trusted only with a checksum written when it was
  # produced, and the file is named by the SHA-256 of the verified .wasm it
  # came from. Trust model: anyone who can write the data directory can already
  # replace the database and the app's config, so this guards against
  # corruption and stale or mismatched files, not against that writer.
  #
  # nil when there is no usable cached file (a rejected one is removed).
  defp load_cached(store, cwasm, bytes) do
    with true <- File.regular?(cwasm),
         :ok <- verify_cwasm(cwasm),
         {:ok, component} <- Components.Component.deserialize_file(store, cwasm, bytes) do
      {:ok, component, "loaded precompiled"}
    else
      false ->
        nil

      error ->
        Logger.warning(
          "Cardigann wasm engine: discarding #{cwasm} (#{inspect(error)}), compiling again"
        )

        File.rm(cwasm)
        File.rm(cwasm <> ".sha256")
        nil
    end
  end

  defp verify_cwasm(cwasm) do
    with {:ok, expected} <- File.read(cwasm <> ".sha256"),
         true <- file_sha256(cwasm) == String.trim(expected) do
      :ok
    else
      _ -> {:error, :cwasm_checksum_mismatch}
    end
  end

  defp file_sha256(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Compiles once, straight into the cache file (0600, in a 0700 directory),
  # records its checksum, then loads that file. nil when the cache cannot be
  # written or loaded (a Wasmex without the patch, a read only data directory):
  # the caller compiles in memory instead.
  defp build_cached(store, cwasm, bytes) do
    tmp = "#{cwasm}.part-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"

    with :ok <- Delivery.ensure_dir(Path.dirname(cwasm)),
         :ok <- Wasmex.Engine.precompile_component_to_file(Wasmex.Engine.default(), bytes, tmp),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- Delivery.write_atomically(cwasm <> ".sha256", file_sha256(tmp) <> "
"),
         :ok <- File.rename(tmp, cwasm),
         {:ok, component} <- Components.Component.deserialize_file(store, cwasm, bytes) do
      {:ok, component, "compiled and cached"}
    else
      error ->
        Logger.warning(
          "Cardigann wasm engine: could not cache the precompiled component " <>
            "(#{inspect(error)}), compiling in memory"
        )

        File.rm(tmp)
        File.rm(cwasm)
        File.rm(cwasm <> ".sha256")
        nil
    end
  rescue
    e in ErlangError ->
      Logger.warning("Cardigann wasm engine: precompile unsupported (#{Exception.message(e)})")
      nil
  end

  defp compile_component(store, bytes) do
    with {:ok, component} <- Components.Component.new(store, bytes),
         do: {:ok, component, "compiled"}
  end

  defp send_phase(phase) do
    if server = Process.whereis(__MODULE__), do: send(server, {:phase, phase})
    :ok
  end

  # Compiling leaves about a GB of freed memory in glibc's arenas, which glibc
  # does not hand back by itself (native/cardigann_guest/BENCH.md, "Memory spike").
  defp release_build_memory do
    :erlang.garbage_collect()

    if Application.get_env(:mydia, :cardigann_wasm_trim, true) do
      try do
        Wasmex.Engine.malloc_trim()
      rescue
        ErlangError -> false
      end
    end

    :ok
  end

  defp compile do
    started = System.monotonic_time()
    # Test seam: lets a test observe a call that gives up while compiling.
    Process.sleep(Application.get_env(:mydia, :cardigann_wasm_compile_delay_ms, 0))

    engine = Wasmex.Engine.default()

    with {:ok, store} <- Components.Store.new_wasi(wasi(), nil, engine),
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
        Logger.warning("Cardigann wasm engine unavailable: #{describe(reason)}")

        if permanent?(reason),
          do: {:unavailable, describe(reason), :permanent},
          else: {:unavailable, describe(reason)}
    end
  rescue
    e ->
      Logger.warning("Cardigann wasm engine failed to compile: #{Exception.message(e)}")
      {:unavailable, "compile failed: #{Exception.message(e)}"}
  end

  # What waiting cannot fix: a file that does not match the pin, and a build
  # that has no pin at all.
  defp permanent?(:no_pin), do: true
  defp permanent?({:checksum_mismatch, _}), do: true
  defp permanent?(_), do: false

  defp describe(reason)
       when reason == :no_pin or
              (is_tuple(reason) and
                 elem(reason, 0) in [
                   :env_path_unreadable,
                   :checksum_mismatch,
                   :download_failed,
                   :write_failed
                 ]),
       do: Delivery.describe(reason)

  defp describe(reason), do: inspect(reason)
end
