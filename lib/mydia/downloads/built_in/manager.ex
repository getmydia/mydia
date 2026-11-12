defmodule Mydia.Downloads.BuiltIn.Manager do
  @moduledoc """
  Decides whether the built-in torrent client runs, and with which settings,
  and applies changes without restarting Mydia.

  It builds `Config` from the layered runtime config, writes the VPN settings
  file for the root-side gluetun loop and starts one `BuiltIn.Supervisor` tree
  under the `Mydia.Downloads.BuiltIn.Instances` `DynamicSupervisor`. It then
  listens on `Mydia.Config.Broadcast.topic/0`: after every reload it rebuilds the
  config and, only when `Config.restart_key/1` differs from the running one,
  stops the whole tree and starts a fresh one with new credentials. A fresh
  tree means a fresh `Vpn` gate, so a new VPN setting always waits for the
  root loop to apply it before the engine runs again.

  The built-in client is on by default, so nothing here may take the
  application down: a failure is logged and the manager keeps running. A tree
  that fails to start leaves the client off with a `{:start_failed, reason}`
  warning on `current/1`, and is retried after 5s, 30s and then every minute
  until one starts or the config changes.

  Options (tests override all of them): `:name`, `:instances` (the
  `DynamicSupervisor`), `:runtime_fun` (returns the `BuiltInTorrent` section),
  `:env_fun` (returns the environment map), `:clients_fun` (returns
  `{types, name_taken?}` or `:unknown`), `:rqbit_path`, `:gluetun_dir`,
  `:api_port` and `:retry_delays` (the start retry schedule in ms; the last
  one repeats).
  """

  use GenServer
  require Logger

  alias Mydia.Config.Broadcast
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Runtime, Status, VpnSettings}

  @instances Mydia.Downloads.BuiltIn.Instances
  # Stopping a tree waits for rqbit to exit (up to 15s), and a call may queue
  # behind an apply that does so.
  @call_timeout_ms 60_000
  @retry_ms 1_000
  # After a tree fails to start: 5s, 30s, then every minute, until one starts
  # or the config changes.
  @start_retry_delays [5_000, 30_000, 60_000]

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The config last evaluated, whether the client is on or off, so warnings such
  as `{:reserved_name_taken}` stay visible while it is off. Nil before the
  first successful evaluation.

  Reads a `:persistent_term`, never the GenServer: it returns at once even
  while an apply is stopping rqbit.
  """
  @spec current(atom()) :: Config.t() | nil
  def current(server \\ __MODULE__), do: :persistent_term.get({__MODULE__, server}, nil)

  @doc """
  Waits until the manager has handled every message sent before the call, then
  returns the config of the running instance (nil when none runs). Blocks for as
  long as an apply in progress takes.
  """
  @spec await_applied(GenServer.server()) :: Config.t() | nil
  def await_applied(server \\ __MODULE__), do: GenServer.call(server, :current, @call_timeout_ms)

  @doc "Re-reads the runtime config and applies it now."
  @spec apply_now(GenServer.server()) :: :ok
  def apply_now(server \\ __MODULE__), do: GenServer.call(server, :apply, @call_timeout_ms)

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Mydia.PubSub, Broadcast.topic())

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      instances: Keyword.get(opts, :instances, @instances),
      runtime_fun:
        Keyword.get(opts, :runtime_fun, fn ->
          Mydia.Settings.get_runtime_config().built_in_torrent
        end),
      env_fun: Keyword.get(opts, :env_fun, &System.get_env/0),
      clients_fun: Keyword.get(opts, :clients_fun, &configured_clients/0),
      rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
      gluetun_dir: Keyword.get(opts, :gluetun_dir),
      api_port: Keyword.get(opts, :api_port),
      retry_delays: Keyword.get(opts, :retry_delays, @start_retry_delays),
      instances_ref: nil,
      current: nil,
      # The restart key of the config that last failed to start, how many
      # times in a row it failed, and the pending retry's token.
      failed_key: nil,
      start_failures: 0,
      retry: nil
    }

    {:ok, state, {:continue, :apply}}
  end

  @impl true
  def handle_continue(:apply, state), do: {:noreply, safe_apply(state)}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.current, state}
  def handle_call(:apply, _from, state), do: {:reply, :ok, safe_apply(state)}

  @impl true
  def handle_info({:runtime_config_reloaded, _config}, state), do: {:noreply, safe_apply(state)}

  # The instances supervisor gave up and was restarted empty: start over.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{instances_ref: ref} = state) do
    Logger.error("built-in torrent client instances stopped: #{inspect(reason)}")
    BuiltIn.clear_runtime()
    Process.send_after(self(), :retry, @retry_ms)
    {:noreply, %{state | instances_ref: nil, current: nil}}
  end

  def handle_info(:retry, state), do: {:noreply, safe_apply(state)}

  # Only the latest scheduled start retry counts; an apply in between
  # replaced or cancelled it.
  def handle_info({:retry_start, token}, %{retry: token} = state),
    do: {:noreply, safe_apply(%{state | retry: nil})}

  def handle_info({:retry_start, _stale}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  # A failure keeps whatever already runs: a broken reload must not stop a
  # working client, and at boot nothing runs yet.
  defp safe_apply(state) do
    apply_config(state)
  rescue
    e ->
      Logger.error("built-in torrent client config not applied: #{Exception.message(e)}")
      state
  catch
    kind, reason ->
      Logger.error("built-in torrent client config not applied: #{inspect({kind, reason})}")
      state
  end

  defp apply_config(state) do
    state = monitor_instances(state)
    env = state.env_fun.()
    config = build_config(state, env)
    remember(config)

    # From render, not from the write: a failed write still gates the engine,
    # which then reports :vpn_apply_timeout instead of running unverified.
    expected_hash = VpnSettings.hash(VpnSettings.render(config, env))
    config = %{config | warnings: config.warnings ++ write_settings(config, env)}
    :persistent_term.put({__MODULE__, state.name}, config)

    if unchanged?(state, config), do: state, else: restart(state, config, expected_hash)
  end

  defp build_config(state, env) do
    {types, name_taken?} =
      case state.clients_fun.() do
        :unknown -> {:unknown, false}
        summary -> summary
      end

    config = Config.from_runtime(state.runtime_fun.(), env, types, name_taken: name_taken?)
    if state.gluetun_dir, do: %{config | gluetun_dir: state.gluetun_dir}, else: config
  end

  # Only the VPN depends on the file. With it off a failed write changes
  # nothing that runs, and installs without /config (bare releases, the NixOS
  # module) would log it on every save.
  defp write_settings(config, env) do
    case VpnSettings.write(config, env) do
      {:ok, _hash} ->
        []

      {:error, reason} when config.vpn? ->
        Logger.error(Status.describe(reason))
        [reason]

      {:error, reason} ->
        Logger.debug(Status.describe(reason))
        []
    end
  end

  defp unchanged?(%{current: nil}, _config), do: false

  defp unchanged?(state, config) do
    Config.restart_key(state.current) == Config.restart_key(config) and
      (not config.enabled? or DynamicSupervisor.which_children(state.instances) != [])
  end

  defp restart(state, config, expected_hash) do
    stop_instances(state.instances)

    # With the client off it is not listed anywhere, so the log is the only
    # place left to say why.
    if {:reserved_name_taken} in config.warnings do
      Logger.warning(Status.describe({:reserved_name_taken}))
    end

    if config.enabled?, do: start_instance(state, config, expected_hash), else: stopped(state)
  end

  defp stopped(state) do
    BuiltIn.clear_runtime()
    %{reset_failures(state) | current: nil}
  end

  defp start_instance(state, config, expected_hash) do
    credentials = {"mydia", Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}
    api_port = state.api_port || config.api_port
    BuiltIn.put_runtime(%Runtime{api_port: api_port, credentials: credentials, config: config})

    tree_opts = [
      config: config,
      credentials: credentials,
      api_port: api_port,
      expected_hash: if(config.vpn?, do: expected_hash),
      rqbit_path: state.rqbit_path
    ]

    case DynamicSupervisor.start_child(state.instances, {BuiltIn.Supervisor, tree_opts}) do
      {:ok, _pid} ->
        %{reset_failures(state) | current: config}

      {:error, reason} ->
        BuiltIn.clear_runtime()
        start_failed(%{state | current: nil}, config, reason)
    end
  end

  # The previous tree is already gone (both need the same API port), so the
  # client stays off until a retry starts it. The failure is kept on the
  # published config, where the admin panel reads why the client is off.
  defp start_failed(state, config, reason) do
    key = Config.restart_key(config)
    failures = if state.failed_key == key, do: state.start_failures + 1, else: 1
    delay = retry_delay(state.retry_delays, failures)

    Logger.error(
      "built-in torrent client not started: #{inspect(reason)}; retrying in #{div(delay, 1000)}s"
    )

    warning = {:start_failed, reason}

    :persistent_term.put({__MODULE__, state.name}, %{
      config
      | warnings: config.warnings ++ [warning]
    })

    token = make_ref()
    Process.send_after(self(), {:retry_start, token}, delay)
    %{state | failed_key: key, start_failures: failures, retry: token}
  end

  defp reset_failures(state), do: %{state | failed_key: nil, start_failures: 0, retry: nil}

  @doc false
  # The default start retry schedule, for tests.
  def retry_delays, do: @start_retry_delays

  @doc false
  # The wait before retry `n` (1-based); the last delay repeats.
  @spec retry_delay([pos_integer()], pos_integer()) :: pos_integer()
  def retry_delay(delays, n), do: Enum.at(delays, n - 1, List.last(delays))

  # Terminating a tree runs Engine.terminate/2, which stops rqbit.
  defp stop_instances(instances) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(instances), is_pid(pid) do
      DynamicSupervisor.terminate_child(instances, pid)
    end

    :ok
  end

  defp monitor_instances(%{instances_ref: nil} = state) do
    case GenServer.whereis(state.instances) do
      pid when is_pid(pid) -> %{state | instances_ref: Process.monitor(pid)}
      _ -> state
    end
  end

  defp monitor_instances(state), do: state

  @doc """
  Records an enabled client in its state directory, so it stays on after the
  user adds clients of their own, and forgets it on an explicit `enabled`
  false. A failed write only costs the stickiness, so it is logged, never
  raised.
  """
  @spec remember(Config.t()) :: :ok
  def remember(%Config{enabled?: true} = config) do
    path = Config.marker_path(config)

    with false <- File.regular?(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:error, reason} <- File.write(path, "") do
      Logger.warning(
        "could not record the built-in torrent client at #{path}: #{inspect(reason)}"
      )
    else
      _ -> :ok
    end

    :ok
  end

  def remember(%Config{explicit: false} = config) do
    _ = File.rm(Config.marker_path(config))
    :ok
  end

  def remember(%Config{}), do: :ok

  @doc """
  The clients configured other than the built-in one, as `summarize_clients/1`
  returns them, or `:unknown` when they could not be read: database rows plus
  DOWNLOAD_CLIENT_<N>_* blocks. The built-in client is rejected explicitly:
  once running it is in the runtime list, and counting it as an rqbit client
  would switch it off.
  """
  @spec configured_clients() :: {[atom()], boolean()} | :unknown
  def configured_clients do
    Mydia.Settings.list_download_client_configs()
    |> Enum.reject(&BuiltIn.managed?(%{connection_settings: &1.connection_settings}))
    |> summarize_clients()
  rescue
    e ->
      Logger.warning(
        "could not read the download clients, so this does not count as a new install for the built-in torrent client: #{Exception.message(e)}"
      )

      :unknown
  end

  @doc """
  Reduces client configs to `{types, name_taken?}` for `Config.from_runtime/4`.
  Every configured client counts, of any type and enabled or not: any of them
  means this is not a new install. A disabled client also takes the reserved
  name, since enabling it later would collide with the built-in client.
  """
  @spec summarize_clients([map()]) :: {[atom()], boolean()}
  def summarize_clients(clients) do
    {Enum.map(clients, & &1.type), Enum.any?(clients, &BuiltIn.reserved_name?(&1.name))}
  end
end
