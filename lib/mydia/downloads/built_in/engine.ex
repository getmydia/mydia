defmodule Mydia.Downloads.BuiltIn.Engine do
  @moduledoc """
  Runs `rqbit server` as a child process and keeps it running.

  The child is opened as a Port and tracked by OS pid, like
  `Mydia.BoundedCommand`, so stopping it kills it rather than orphaning it.
  The pid is also written to `<state_dir>/rqbit.pid` so a child left behind by
  a crashed BEAM is killed on the next start.

  It restarts with backoff up to 5 times, then holds `:crashed` until
  `restart/1`. With the VPN on, the binary is installed setgid
  `mydia-torrent` in the image, which is what puts its traffic in the tunnel.
  """

  use GenServer
  require Logger

  alias Mydia.Downloads.BuiltIn.{Config, Status}

  @max_restarts 5
  @stable_ms 60_000
  @kill_wait_ms 5_000
  @poll_ms 50

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the child on `listen_port`, or restarts it when the port or the
  listen address differs from the running one. `listen_ip` is the tunnel
  address in VPN mode and `nil` otherwise.
  """
  def start_engine(server \\ __MODULE__, listen_port, listen_ip \\ nil),
    do: GenServer.call(server, {:start, listen_port, listen_ip})

  def stop_engine(server \\ __MODULE__, reason), do: GenServer.call(server, {:stop, reason})
  def restart(server \\ __MODULE__), do: GenServer.call(server, :restart)

  # `--listen-ip` pins the listening sockets to the tunnel address. Bound to
  # 0.0.0.0, replies to inbound UDP (uTP, DHT) pick the eth0 source address
  # before the split-tunnel mark applies, and gluetun's MASQUERADE then remaps
  # the source port.
  @spec args(Config.t(), pos_integer(), pos_integer(), String.t() | nil) :: [String.t()]
  def args(%Config{} = config, api_port, listen_port, listen_ip \\ nil) do
    bind = if config.vpn?, do: ["--bind-device", config.vpn_interface], else: []
    listen = if is_binary(listen_ip), do: ["--listen-ip", listen_ip], else: []

    ["--http-api-listen-addr", "127.0.0.1:#{api_port}", "--listen-port", "#{listen_port}"] ++
      listen ++
      ["--disable-upnp-port-forward"] ++
      bind ++
      ["server", "start", "--persistence-location", config.state_dir, config.download_path]
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)

    state = %{
      config: config,
      status: Keyword.get(opts, :status, Status),
      rqbit_path: Keyword.get(opts, :rqbit_path, "rqbit"),
      api_port: Keyword.get(opts, :api_port, 3030),
      credentials: Keyword.fetch!(opts, :credentials),
      backoff_ms: Keyword.get(opts, :backoff_ms, 2_000),
      env: Keyword.get(opts, :env, []),
      port: nil,
      os_pid: nil,
      listen_port: nil,
      listen_ip: nil,
      restarts: 0,
      desired: :stopped,
      crashed?: false,
      timer: nil,
      started_at: nil
    }

    kill_stale(config.state_dir)

    if Keyword.get(opts, :autostart, false) do
      send(self(), {:autostart, config.port})
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:start, listen_port, listen_ip}, _from, %{port: nil} = state) do
    state =
      cancel_timer(%{state | listen_port: listen_port, listen_ip: listen_ip, desired: :running})

    {:reply, :ok, spawn_child(%{state | restarts: 0, crashed?: false})}
  end

  def handle_call(
        {:start, listen_port, listen_ip},
        _from,
        %{listen_port: listen_port, listen_ip: listen_ip} = state
      ),
      do: {:reply, :ok, state}

  def handle_call({:start, listen_port, listen_ip}, _from, state) do
    state = state |> cancel_timer() |> kill_child()

    state = %{
      state
      | listen_port: listen_port,
        listen_ip: listen_ip,
        desired: :running,
        restarts: 0,
        crashed?: false
    }

    {:reply, :ok, spawn_child(state)}
  end

  def handle_call({:stop, reason}, _from, state) do
    state = %{state | desired: :stopped} |> cancel_timer() |> kill_child()
    Status.put(state.status, :engine, {:stopped, reason})
    {:reply, :ok, state}
  end

  # Only leaves a crash; any other state is managed by start_engine/stop_engine,
  # and a restart must not bypass the VPN gate that stopped the engine.
  def handle_call(:restart, _from, %{crashed?: true, listen_port: port} = state)
      when not is_nil(port) do
    state = %{state | desired: :running, restarts: 0, crashed?: false}
    {:reply, :ok, spawn_child(cancel_timer(state))}
  end

  def handle_call(:restart, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:autostart, port}, state) do
    Status.put(state.status, :port, {:static, port})
    {:noreply, spawn_child(%{state | listen_port: port, desired: :running})}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("rqbit: " <> String.trim_trailing(data))
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("rqbit exited with code #{code}")
    uptime = System.monotonic_time(:millisecond) - state.started_at
    restarts = if uptime >= @stable_ms, do: 0, else: state.restarts
    state = %{state | port: nil, os_pid: nil, restarts: restarts}

    if restarts >= @max_restarts do
      Status.put(state.status, :engine, {:crashed, {:engine_exit, code}, restarts})
      {:noreply, %{state | crashed?: true}}
    else
      delay = state.backoff_ms * Integer.pow(2, restarts)
      Status.put(state.status, :engine, :starting)
      timer = Process.send_after(self(), :respawn, delay)
      {:noreply, %{state | restarts: restarts + 1, timer: timer}}
    end
  end

  def handle_info(:respawn, %{desired: :running, port: nil} = state),
    do: {:noreply, spawn_child(%{state | timer: nil})}

  # Stale messages from a killed child, or a timer that lost a race with a
  # stop or start.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: kill_child(state)

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp spawn_child(state) do
    case System.find_executable(state.rqbit_path) do
      nil ->
        Status.put(state.status, :engine, {:crashed, :rqbit_not_found, 0})
        %{state | crashed?: true}

      path ->
        case ensure_dirs(state.config) do
          :ok ->
            spawn_rqbit(path, state)

          {:error, dir, reason} ->
            Status.put(state.status, :engine, {:crashed, {:path_unwritable, dir, reason}, 0})
            %{state | crashed?: true}
        end
    end
  end

  defp ensure_dirs(config) do
    Enum.find_value([config.state_dir, config.download_path], :ok, fn dir ->
      case File.mkdir_p(dir) do
        :ok -> nil
        {:error, reason} -> {:error, dir, reason}
      end
    end)
  end

  defp spawn_rqbit(path, state) do
    {user, pass} = state.credentials

    env =
      [{"RQBIT_HTTP_BASIC_AUTH_USERPASS", "#{user}:#{pass}"} | state.env]
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case open_port(path, env, state) do
      {:ok, port, os_pid} ->
        adopt_child(state, port, os_pid)

      {:error, reason} ->
        # Raising here would loop through the supervisor and take the app down
        # for users who never configured the built-in client.
        Logger.error("could not spawn rqbit: #{reason}")
        Status.put(state.status, :engine, {:crashed, {:spawn_failed, reason}, 0})
        %{state | crashed?: true}
    end
  end

  defp open_port(path, env, state) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args(state.config, state.api_port, state.listen_port, state.listen_ip),
        env: env
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        {:ok, port, os_pid}

      _ ->
        close_quietly(port)
        {:error, "no OS pid for the spawned process"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, inspect({kind, reason})}
  end

  defp close_quietly(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp adopt_child(state, port, os_pid) do
    # The state owns the child before anything else can fail, so a pid
    # file write error cannot orphan it.
    state = %{
      state
      | port: port,
        os_pid: os_pid,
        started_at: System.monotonic_time(:millisecond)
    }

    case File.write(pid_file(state.config.state_dir), Integer.to_string(os_pid)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not write rqbit pid file: #{inspect(reason)}")
    end

    Status.put(state.status, :engine, :running)
    state
  end

  defp kill_child(%{port: nil} = state), do: state

  defp kill_child(state) do
    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    terminate_pid(state.os_pid)
    File.rm(pid_file(state.config.state_dir))
    %{state | port: nil, os_pid: nil}
  end

  defp kill_stale(state_dir) do
    with {:ok, contents} <- File.read(pid_file(state_dir)),
         {pid, ""} <- Integer.parse(String.trim(contents)),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- String.contains?(cmdline, "rqbit") do
      terminate_pid(pid)
    end

    File.rm(pid_file(state_dir))
  end

  # TERM, wait for the process to be gone, then KILL if it ignored us.
  defp terminate_pid(pid) do
    signal("TERM", pid)

    unless wait_gone(pid, @kill_wait_ms) do
      signal("KILL", pid)
      wait_gone(pid, @kill_wait_ms)
    end

    :ok
  end

  defp signal(name, pid),
    do: System.cmd("kill", ["-#{name}", Integer.to_string(pid)], stderr_to_stdout: true)

  defp wait_gone(pid, remaining) do
    cond do
      gone?(pid) ->
        true

      remaining <= 0 ->
        false

      true ->
        Process.sleep(@poll_ms)
        wait_gone(pid, remaining - @poll_ms)
    end
  end

  # A zombie has already exited and only awaits reaping.
  defp gone?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.starts_with?("Z")
      {:error, _} -> true
    end
  end

  defp pid_file(state_dir), do: Path.join(state_dir, "rqbit.pid")
end
