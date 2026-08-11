defmodule Mydia.Plugins.Host do
  @moduledoc """
  WASM **component-model** runtime host for the plugin platform.

  Guests are WebAssembly components built against the canonical
  `mydia:plugin@1.2.0` WIT contract (`native/mydia_plugin_sdk/wit/plugin.wit`).
  The host instantiates them through `Wasmex.Components.*` and calls the typed
  `handler.on-event` / `handler.on-schedule` exports. A guest built against an
  older minor (1.0 or 1.1) is served the matching namespace + export, detected from the
  component bytes at `start_plugin` (`detect_legacy/1`), so old guests keep
  working against the 1.2 host.

  Each installed plugin gets its own `NimblePool`, which bounds how many guests
  run concurrently on the dirty NIF schedulers. Each *invocation* checks out a
  slot and runs against a **fresh component instance + store** (KTD9), so guests
  never share mutable linear memory across calls.

  ## Sandbox (R11)

  `Wasmex.Wasi.WasiP2Options` defaults are *permissive* (`inherit_std* : true`),
  so every store is built with stdin/stdout/stderr inheritance **off** and
  `allow_http: false`. A guest therefore has no ambient stdio, filesystem, or
  network access; the only way out is an explicit, capability-gated host-function
  import (`Mydia.Plugins.HostFunctions`, wired in U4).

  ## Resource limiting (KTD4)

  `Wasmex.StoreLimits` caps linear memory on every store. Two residuals of the
  beta component runtime narrow what that buys versus the core-wasm host:

    * **Memory cap is instantiation-time only.** Wasmex 0.14 enforces
      `StoreLimits.memory_size` when a component is instantiated (one whose
      *minimum* linear memory exceeds the cap is refused), but does **not** cap
      runtime `memory.grow` on a component store — a guest can allocate past the
      cap at runtime. The cap therefore bounds a plugin's declared footprint, not
      a runaway allocation.
    * **No CPU metering.** Fuel is not available for component stores in Wasmex
      0.14 (`set_fuel` rejects a `Components.Store`), so the forced-fuel dispatch
      guard of the core-wasm host is dropped. With no fuel/epoch interruption, a
      runaway guest's dirty-NIF thread is not reclaimed until it yields.

  The runtime guards that remain are the instantiation-time memory cap,
  fresh-store isolation, and the per-call wall-clock timeout + `Process.exit(:kill)`
  (which reclaims the Elixir process; the OS thread of a wedged guest is the
  bounded residual). Both residuals are accepted under the curated-index trust
  model and tracked as Wasmex upstream requests (see the plan's Deferred work).

  ## Boundary (KTD2)

  The host↔guest boundary is the typed WIT contract, not hand-rolled JSON over
  linear memory. The host marshals the dispatcher's event payload into the WIT
  `event` record (the arbitrary per-event metadata bag rides along as a JSON
  string in `metadata-json`), calls `on-event`, and decodes the guest's small
  JSON result string. Host-function imports receive and return typed WIT records
  directly — no `caller`-memory marshalling.

  ## Diagnostics

  Host markers bracket every invocation (start/end, with outcome + duration) so a
  run is always visible in the activity timeline, even one that traps before the
  guest emits anything. Guest narration flows through the ungated `log` host
  function (U4). The core-wasm host's WASI stdout/stderr pipe capture is gone:
  `WasiP2Options` exposes no pipe redirection (only inherit booleans), and the
  sandbox denies stdio, so a locked-down component has no host-visible stdio.
  """

  @behaviour NimblePool

  require Logger

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Log
  alias Mydia.Plugins.Logs
  alias Mydia.Plugins.SingleFlight
  alias Wasmex.Components
  alias Wasmex.Wasi.WasiP2Options

  @registry Mydia.Plugins.PoolRegistry
  @supervisor Mydia.Plugins.PoolSupervisor

  # The typed handler exports, addressed by their interface path. The interface
  # version is part of the path because the WIT package version IS the ABI
  # version; wasmtime semver-matches so a 1.1 guest's `handler@1.1.0/on-event`
  # still resolves against this 1.2 lookup. `on-schedule` is 1.1+ — a 1.0
  # guest has no such export and the schedule call fails soft.
  @handler_export ["mydia:plugin/handler@1.2.0", "on-event"]
  @schedule_export ["mydia:plugin/handler@1.2.0", "on-schedule"]
  @v11_handler_export ["mydia:plugin/handler@1.1.0", "on-event"]
  @v11_schedule_export ["mydia:plugin/handler@1.1.0", "on-schedule"]
  @legacy_handler_export ["mydia:plugin/handler@1.0.0", "on-event"]

  # Provided host-import namespaces. wasmex links the provided imports map to the
  # guest's *exact* imported package name (no semver fuzzing), so a 1.0 guest
  # (which imports `host@1.0.0` with only the original three functions) needs the
  # map re-keyed and narrowed. 1.1 guests are served via a parallel key that
  # `HostFunctions.imports_for/2` publishes alongside 1.2. We detect the contract
  # once per plugin from the bytes and memoize it.
  @host_namespace "mydia:plugin/host@1.2.0"
  @v11_host_namespace "mydia:plugin/host@1.1.0"
  @legacy_host_namespace "mydia:plugin/host@1.0.0"
  @legacy_host_funcs ~w(http-request data-read log)

  @type slug :: String.t()

  # A per-invocation context handed to an imports builder so host-function
  # closures can correlate to the run without a shared registry.
  @type invocation_ctx :: %{slug: slug(), invocation_id: String.t(), test_run: boolean()}

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Validates `wasm_bytes` as a component and starts a pool for `slug`.

  Options:

    * `:imports` - host-function imports for every instance. Either a static
      nested map (`%{"mydia:plugin/host" => %{"http-request" => {:fn, f}}}`) or a
      1-arity builder `(invocation_ctx -> map)` invoked per call so closures can
      capture the invocation context (U4 supplies the latter). Defaults to `%{}`.
    * `:pool_size` - worker count (defaults to `plugins.pool_size` config)
  """
  @spec start_plugin(slug(), binary(), keyword()) ::
          {:ok, pid()} | {:error, Error.t()}
  def start_plugin(slug, wasm_bytes, opts \\ [])
      when is_binary(slug) and is_binary(wasm_bytes) do
    with :ok <- validate_component(wasm_bytes) do
      # Detect the guest's contract version up front (wasmex links the provided
      # imports lazily at first call and rejects a package the guest doesn't
      # import, so we cannot probe by instantiation). The component embeds its
      # imported interface names as UTF-8; a guest that does not import the 1.2
      # or 1.1 host interface is served the 1.0 namespace + export.
      :persistent_term.put({__MODULE__, :contract, slug}, detect_contract(wasm_bytes))

      worker_arg = %{
        slug: slug,
        bytes: wasm_bytes,
        imports: Keyword.get(opts, :imports, %{})
      }

      pool_opts = [
        worker: {__MODULE__, worker_arg},
        pool_size: Keyword.get(opts, :pool_size, config().pool_size),
        lazy: true,
        name: via(slug)
      ]

      case DynamicSupervisor.start_child(@supervisor, pool_child_spec(slug, pool_opts)) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, Error.new(:instantiate_failed, inspect(reason))}
      end
    end
  end

  @doc "Stops the pool for `slug`, if running."
  @spec stop_plugin(slug()) :: :ok
  def stop_plugin(slug) do
    case Registry.lookup(@registry, slug) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end

    # Drop the memoized contract-version verdict so a re-installed (possibly
    # rebuilt) artifact is re-detected on next start.
    :persistent_term.erase({__MODULE__, :contract, slug})
    :ok
  end

  @doc "True when a pool is running for `slug`."
  @spec running?(slug()) :: boolean()
  def running?(slug), do: Registry.lookup(@registry, slug) != []

  @doc """
  Invokes the guest's `handler.on-event` export with `payload` (the dispatcher's
  event map, as built by `Mydia.Plugins.build_payload/1`), returning the decoded
  result map.

  The `function` argument is retained for call-site compatibility but ignored:
  the component model addresses the typed export directly, not by name.

  Options:

    * `:timeout` - per-call deadline in ms (defaults to config)
    * `:test_run` - badge the markers/guest logs for this run as a test
    * `:memory_limit_bytes` - override the linear-memory cap for this call
      (defaults to config; a test seam for exercising `StoreLimits`)
    * `:handler` - `:on_event` (default) or `:on_schedule`
    * `:single_flight` - `:wait` (default; block until the plugin's lock is free)
      or `:skip` (return a `:busy` error if a sibling invocation is in flight —
      the scheduler's non-reentrancy)
  """
  @spec call(slug(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def call(slug, function, payload, opts \\ [])
      when is_binary(slug) and is_binary(function) and is_map(payload) do
    cfg = config()
    handler = Keyword.get(opts, :handler, :on_event)
    timeout = Keyword.get(opts, :timeout, default_timeout(cfg, handler))
    mode = Keyword.get(opts, :single_flight, :wait)

    invocation = %{
      slug: slug,
      invocation_id: Ecto.UUID.generate(),
      test_run: Keyword.get(opts, :test_run, false),
      function: function,
      handler: handler,
      payload: payload,
      memory_limit_bytes: Keyword.get(opts, :memory_limit_bytes, cfg.memory_limit_bytes),
      timeout: timeout
    }

    # Serialize invocations per plugin so shared KV state is consistent (U4). A
    # `:skip` acquirer (the scheduler) bails out without running when busy; a
    # `:wait` acquirer queues behind the in-flight invocation.
    case SingleFlight.run(slug, mode, fn -> invoke_with_markers(invocation) end) do
      {:busy} -> {:error, Error.new(:busy, "plugin #{slug} invocation already in flight")}
      result -> result
    end
  end

  defp invoke_with_markers(invocation) do
    %{slug: slug, timeout: timeout} = invocation

    # Host markers bracket every invocation on both call paths (dispatch and
    # direct) so a run is always visible in the timeline — even one that traps
    # before the guest emits anything (R3, AE1).
    emit_start_marker(invocation)
    started_at = System.monotonic_time(:millisecond)

    result =
      try do
        # The checkout deadline gives the slot back even if the run wedges; the
        # inner per-call timeout is the primary deadline.
        NimblePool.checkout!(
          via(slug),
          :checkout,
          fn _from, worker ->
            {run_invocation(worker, invocation), :ok}
          end,
          timeout + 1_000
        )
      catch
        :exit, {:noproc, _} ->
          {:error, Error.new(:not_found, "plugin #{slug} is not running")}

        :exit, {:timeout, _} ->
          {:error, Error.new(:timeout, "plugin #{slug} timed out after #{timeout}ms")}
      end

    emit_end_marker(invocation, result, System.monotonic_time(:millisecond) - started_at)
    result
  end

  # ── Component validation ──────────────────────────────────────────────────

  @doc false
  @spec validate_component(binary()) :: :ok | {:error, Error.t()}
  def validate_component(wasm_bytes) do
    # Compile the component once at install time so non-component bytes or a
    # contract the host cannot satisfy fail fast with a clear error, rather than
    # at the first event. The throwaway store is discarded; each invocation
    # builds its own.
    with {:ok, store} <- Components.Store.new(),
         {:ok, _component} <- Components.Component.new(store, wasm_bytes) do
      :ok
    else
      {:error, reason} -> {:error, Error.new(:compile_failed, to_string_reason(reason))}
    end
  end

  # ── Invocation ──────────────────────────────────────────────────────────

  defp run_invocation(worker, inv) do
    %{slug: slug, bytes: bytes, imports: imports_spec} = worker

    limits = %Wasmex.StoreLimits{memory_size: inv.memory_limit_bytes}

    # Re-lock the sandbox: WasiP2Options defaults inherit host stdio, so deny all
    # three and keep HTTP off. Egress is only ever the gated host function (R11).
    wasi = %WasiP2Options{
      inherit_stdin: false,
      inherit_stdout: false,
      inherit_stderr: false,
      allow_http: false
    }

    full_imports = build_imports(imports_spec, inv)
    instantiate(slug, bytes, wasi, limits, full_imports, inv)
  end

  # Instantiate the guest with imports matching its contract version. A 1.0 guest
  # imports `host@1.0.0` (three functions); wasmex links the provided imports to
  # the guest's exact imported package name, so the map is re-keyed/narrowed for
  # legacy guests (detected from the bytes at start_plugin).
  defp instantiate(slug, bytes, wasi, limits, full_imports, inv) do
    imports =
      if contract(slug) == :v10, do: to_legacy_imports(full_imports), else: full_imports

    case Components.start_link(%{
           bytes: bytes,
           wasi: wasi,
           store_limits: limits,
           imports: imports
         }) do
      {:ok, pid} -> run_in_instance(pid, inv)
      {:error, reason} -> {:error, Error.new(:instantiate_failed, to_string_reason(reason))}
    end
  end

  defp run_in_instance(pid, inv) do
    # start_link links the fresh instance GenServer to this checkout process;
    # unlink so killing the disposable instance (below, or on a hung guest)
    # never propagates an exit back to the caller.
    Process.unlink(pid)

    try do
      invoke(pid, inv)
    after
      Process.exit(pid, :kill)
    end
  end

  # Re-key the full 1.2 imports map to the 1.0 namespace, keeping only the three
  # functions a 1.0 guest imports.
  defp to_legacy_imports(full_imports) do
    funcs =
      Map.get(full_imports, @host_namespace) ||
        Map.get(full_imports, @v11_host_namespace, %{})

    %{@legacy_host_namespace => Map.take(funcs, @legacy_host_funcs)}
  end

  # A guest's contract version is read from the UTF-8 interface names embedded
  # in the component bytes. 1.2 and 1.1 both get the full imports map (published
  # under both namespace keys); only 1.0 needs the narrowed legacy map.
  defp detect_contract(bytes) do
    cond do
      String.contains?(bytes, @host_namespace) -> :v12
      String.contains?(bytes, @v11_host_namespace) -> :v11
      true -> :v10
    end
  end

  defp contract(slug), do: :persistent_term.get({__MODULE__, :contract, slug}, :v12)

  # A static map is used as-is; a builder is called per invocation so closures
  # can capture this run's context (slug + invocation id, for log correlation).
  defp build_imports(spec, inv) when is_function(spec, 1), do: spec.(invocation_ctx(inv))
  defp build_imports(spec, _inv) when is_map(spec), do: spec

  defp invocation_ctx(inv) do
    %{slug: inv.slug, invocation_id: inv.invocation_id, test_run: inv.test_run}
  end

  defp invoke(pid, inv) do
    {export, record} = handler_call(inv)
    args = Components.FieldConverter.maybe_convert_args([record], true)

    case Components.call_function(pid, export, args, inv.timeout) do
      {:ok, {:ok, json}} -> decode_result(json)
      {:ok, {:error, message}} -> {:error, Error.new(:guest_error, sanitize_message(message))}
      {:error, reason} -> {:error, Error.new(:trap, to_string_reason(reason))}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, Error.new(:timeout, "invocation timed out after #{inv.timeout}ms")}
  end

  # Pick the export + marshalled record for the requested handler. on-schedule
  # is 1.1+; a 1.0 guest lacks the export and call_function returns an error
  # the caller surfaces (fail-soft, no crash). on-event resolves at the guest's
  # own interface version (detected during start_plugin).
  defp handler_call(%{handler: :on_schedule, slug: slug, payload: payload}) do
    export =
      case contract(slug) do
        :v11 -> @v11_schedule_export
        _ -> @schedule_export
      end

    {export, to_schedule_record(payload)}
  end

  defp handler_call(%{slug: slug, payload: payload}) do
    export =
      case contract(slug) do
        :v10 -> @legacy_handler_export
        :v11 -> @v11_handler_export
        :v12 -> @handler_export
      end

    {export, to_event_record(payload)}
  end

  # Known envelope keys that map to typed `event` record fields; everything else
  # in the payload (the `metadata` bag, the injected `config`, any future extra)
  # rides along verbatim in `metadata-json` so nothing is silently dropped.
  @envelope_keys ~w(event category severity actor_type actor_id resource_type resource_id)

  # Marshal the dispatcher payload into the WIT `event` record.
  defp to_event_record(payload) do
    %{
      event: to_string(Map.get(payload, "event") || ""),
      category: opt_string(Map.get(payload, "category")),
      severity: opt_string(Map.get(payload, "severity")),
      actor_type: opt_string(Map.get(payload, "actor_type")),
      actor_id: opt_string(Map.get(payload, "actor_id")),
      resource_type: opt_string(Map.get(payload, "resource_type")),
      resource_id: opt_string(Map.get(payload, "resource_id")),
      metadata_json: Jason.encode!(Map.drop(payload, @envelope_keys))
    }
  end

  # Marshal a schedule payload into the WIT `schedule-tick` record. The operator
  # settings ride along as a JSON string in `config-json` (U4 injects them under
  # the "config" key, like the durable notifier path).
  defp to_schedule_record(payload) do
    %{
      slug: to_string(Map.get(payload, "slug") || ""),
      now: schedule_now(payload),
      config_json: Jason.encode!(Map.get(payload, "config") || %{})
    }
  end

  defp schedule_now(payload) do
    case Map.get(payload, "now") do
      now when is_integer(now) -> now
      _ -> System.system_time(:second)
    end
  end

  defp opt_string(nil), do: :none
  defp opt_string(value), do: {:some, to_string(value)}

  # The guest returns a small JSON result string (`result<string, string>` ok
  # case). An empty string means "no structured result".
  defp decode_result(json) when is_binary(json) do
    trimmed = String.trim(json)

    if trimmed == "" do
      {:ok, %{}}
    else
      case Jason.decode(trimmed) do
        {:ok, decoded} when is_map(decoded) ->
          {:ok, decoded}

        {:ok, other} ->
          {:error,
           Error.new(:invalid_output, "guest result is not a JSON object: #{inspect(other)}")}

        {:error, _} ->
          {:error, Error.new(:invalid_output, "guest result is not valid JSON")}
      end
    end
  end

  # ── Debug log markers (U2) ────────────────────────────────────────────────

  defp emit_start_marker(inv) do
    Logs.create_async(%{
      slug: inv.slug,
      invocation_id: inv.invocation_id,
      source: :host,
      level: :debug,
      message: "invoke #{inv.function}",
      metadata: start_metadata(inv),
      test_run: inv.test_run
    })
  end

  defp start_metadata(inv) do
    base = %{"phase" => "start", "function" => inv.function}

    case event_type(inv.payload) do
      nil -> base
      type -> Map.put(base, "event", type)
    end
  end

  defp event_type(payload) when is_map(payload),
    do: Map.get(payload, :event) || Map.get(payload, "event")

  defp event_type(_), do: nil

  defp emit_end_marker(inv, result, duration_ms) do
    {level, outcome, detail} = classify_outcome(result)

    metadata =
      %{
        "phase" => "end",
        "function" => inv.function,
        "outcome" => outcome,
        "duration_ms" => duration_ms
      }
      |> maybe_put("detail", detail)

    Logs.create_async(%{
      slug: inv.slug,
      invocation_id: inv.invocation_id,
      source: :host,
      level: level,
      message: end_message(outcome, inv.function, duration_ms, detail),
      metadata: metadata,
      test_run: inv.test_run
    })
  end

  defp classify_outcome({:ok, result}), do: {:info, "ok", result_summary(result)}

  defp classify_outcome({:error, %Error{type: type, message: message}}),
    do: {:error, to_string(type), sanitize_detail(message)}

  # Defensive: every run_invocation path is {:ok,_}|{:error,%Error{}}, but a
  # catch-all keeps an unexpected shape from raising in the marker path.
  defp classify_outcome(_other), do: {:error, "unknown", nil}

  # A compact "key=value" summary of the guest's returned result map, surfaced in
  # the end-marker so a successful run shows what it did (e.g. `pulled=2 pushed=1`)
  # instead of a bare "ok". Zero/empty/falsey values are dropped to keep the line
  # short, so a no-op run still reads as plain "ok". Keys are sorted for a stable
  # ordering. Returns nil when nothing is worth showing.
  defp result_summary(result) when is_map(result) and map_size(result) > 0 do
    case result |> Enum.sort() |> Enum.flat_map(&summary_pair/1) |> Enum.join(" ") do
      "" -> nil
      summary -> summary
    end
  end

  defp result_summary(_), do: nil

  defp summary_pair({_key, value}) when value in [nil, 0, false, "", []], do: []
  defp summary_pair({key, value}) when is_list(value), do: ["#{key}=#{length(value)}"]
  defp summary_pair({key, value}) when is_map(value), do: ["#{key}=#{map_size(value)}"]

  defp summary_pair({key, value}) when is_binary(value) or is_number(value) or is_boolean(value),
    do: ["#{key}=#{value}"]

  defp summary_pair(_), do: []

  # A guest trap/error message can carry non-UTF-8 bytes; this detail lands in
  # marker metadata which JsonMapType encodes with Jason, which raises on invalid
  # UTF-8 — dropping the very end-marker that records the trap.
  defp sanitize_detail(nil), do: nil
  defp sanitize_detail(message) when is_binary(message), do: Log.sanitize(message)
  defp sanitize_detail(message), do: message

  defp sanitize_message(message) when is_binary(message), do: Log.sanitize(message)
  defp sanitize_message(message), do: to_string_reason(message)

  defp end_message(outcome, function, ms, nil), do: "#{function} #{outcome} (#{ms}ms)"

  defp end_message(outcome, function, ms, detail),
    do: "#{function} #{outcome} (#{ms}ms) #{detail}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── NimblePool callbacks ────────────────────────────────────────────────

  @impl NimblePool
  def init_worker(pool_state) do
    # The worker just carries the validated component bytes + imports spec; a
    # fresh instance is built per invocation, so there is no per-worker store.
    {:ok, pool_state, pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, worker_state, pool_state) do
    {:ok, worker_state, worker_state, pool_state}
  end

  @impl NimblePool
  def handle_checkin(_client_state, _from, worker_state, pool_state) do
    {:ok, worker_state, pool_state}
  end

  @impl NimblePool
  def terminate_worker(_reason, _worker_state, pool_state) do
    {:ok, pool_state}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp pool_child_spec(slug, pool_opts) do
    Supervisor.child_spec({NimblePool, pool_opts}, id: {__MODULE__, slug})
  end

  defp via(slug), do: {:via, Registry, {@registry, slug}}

  defp config do
    case Application.get_env(:mydia, :runtime_config) do
      %{plugins: %{} = plugins} -> plugins
      _ -> Mydia.Config.Schema.defaults().plugins
    end
  end

  # on-schedule gets the larger schedule budget; everything else the event budget.
  defp default_timeout(cfg, :on_schedule), do: Map.get(cfg, :schedule_timeout_ms) || 60_000
  defp default_timeout(cfg, _handler), do: cfg.invocation_timeout_ms

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end
