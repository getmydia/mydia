defmodule Mydia.Downloads.BuiltIn.Vpn do
  @moduledoc """
  Gates the built-in engine on the VPN.

  Gluetun is started by the container entrypoint as root, so this process only
  observes it: the entrypoint's preflight file, then gluetun's control server.
  The engine starts only while gluetun reports `running` and the leak check
  passed for the current tunnel; anything else stops it with a named reason.

  `Status` is only written when a value changes, so a steady tunnel does not
  re-broadcast on every poll. Engine calls are idempotent and repeat each poll.
  """

  use GenServer
  require Logger

  alias Mydia.Downloads.BuiltIn.{Engine, GluetunClient, LeakCheck, Status}

  # A gluetun restart between two polls can come back on the same public and
  # tunnel addresses, so a passed leak check also expires with time. This
  # bounds how long such a restart goes unverified, at two relay requests per
  # check.
  @reverify_ms 60_000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def init(opts) do
    engine = Keyword.get(opts, :engine, Engine)

    state = %{
      config: Keyword.fetch!(opts, :config),
      status: Keyword.get(opts, :status, Status),
      base_url: Keyword.get(opts, :base_url, "http://127.0.0.1:8000"),
      interval_ms: Keyword.get(opts, :interval_ms, 10_000),
      engine_fun: Keyword.get(opts, :engine_fun, default_engine_fun(engine)),
      leak_check:
        Keyword.get(opts, :leak_check, fn public_ip ->
          LeakCheck.run(relay_url: Mydia.Metadata.metadata_relay_url(), expected_ip: public_ip)
        end),
      tunnel_ip_fun: Keyword.get(opts, :tunnel_ip_fun, &read_tunnel_ip/1),
      reverify_ms: Keyword.get(opts, :reverify_ms, @reverify_ms),
      verified: nil,
      last_vpn: :connecting,
      last_port: nil
    }

    Status.put(state.status, :vpn, :connecting)
    {:ok, state, {:continue, :stop_engine}}
  end

  # Vpn can restart without Engine restarting (rest_for_one only restarts
  # later siblings), so a fresh Vpn must not inherit a running, ungated engine.
  # Done after init: stopping rqbit can take longer than start_link waits.
  @impl true
  def handle_continue(:stop_engine, state) do
    call_engine(state, {:stop, :vpn_connecting})
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = safe_poll(state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  # Any failure while observing the tunnel fails closed instead of crashing.
  defp safe_poll(state) do
    poll(state)
  rescue
    e ->
      Logger.error("VPN gate poll raised: #{Exception.format(:error, e, __STACKTRACE__)}")
      down(state, {:leak_check_failed, Exception.message(e)})
  catch
    kind, reason ->
      Logger.error("VPN gate poll failed: #{inspect({kind, reason})}")
      down(state, {:leak_check_failed, inspect(reason)})
  end

  defp poll(state) do
    with :ok <- preflight(state.config.gluetun_dir),
         {:ok, req} <- client(state),
         {:ok, "running"} <- status(req, state) do
      up(req, state)
    else
      {:down, reason} -> down(state, reason)
    end
  end

  # The engine listens on the tunnel address, so an unreadable one gets the
  # same treatment as an unreadable public address. Both are read every poll,
  # so a changed address restarts the engine through `Engine.start_engine/3`.
  defp up(req, state) do
    with {:ok, ip} when is_binary(ip) and ip != "" <- GluetunClient.public_ip(req),
         {:ok, tunnel_ip} <- state.tunnel_ip_fun.(state.config.vpn_interface) do
      verify_and_start(req, ip, tunnel_ip, state)
    else
      _ -> connecting(state)
    end
  end

  # The tunnel is up but an address is unreadable, so it cannot be verified.
  defp connecting(state) do
    state = put_vpn(state, :connecting)
    call_engine(state, {:stop, :vpn_connecting})
    %{state | verified: nil}
  end

  # A new public or tunnel address means the tunnel restarted since the last
  # leak check; so may an old check, see @reverify_ms.
  defp verify_and_start(req, ip, tunnel_ip, state) do
    now = System.monotonic_time(:millisecond)

    case state.verified do
      {^ip, ^tunnel_ip, at} when now - at < state.reverify_ms ->
        start_engine(req, ip, tunnel_ip, state)

      _ ->
        case state.leak_check.(ip) do
          :ok -> start_engine(req, ip, tunnel_ip, %{state | verified: {ip, tunnel_ip, now}})
          {:error, reason} -> down(state, reason)
        end
    end
  end

  defp start_engine(req, ip, tunnel_ip, state) do
    state = put_vpn(state, {:up, %{provider: state.config.vpn_provider, public_ip: ip}})

    {state, port} = listen_port(GluetunClient.forwarded_port(req), state)
    call_engine(state, {:start, port, tunnel_ip})
    state
  end

  # Once a port was forwarded on this tunnel, a failed or empty read keeps the
  # engine on that port and reports the failure, instead of restarting rqbit
  # on the static port and back. The static port is only for a tunnel that
  # never had one forwarded.
  defp listen_port({:ok, n}, state) when is_integer(n) and n > 0,
    do: {put_port(state, {:forwarded, n}), n}

  defp listen_port(result, %{last_port: {:forwarded, last, _since}} = state),
    do: forward_failed(result, last, state)

  defp listen_port(result, %{last_port: {:failed, _reason, last}} = state),
    do: forward_failed(result, last, state)

  defp listen_port(_result, state),
    do: {put_port(state, {:static, state.config.port}), state.config.port}

  defp forward_failed(result, last, state),
    do: {put_port(state, {:failed, {:port_forward_failed, forward_error(result)}, last}), last}

  defp forward_error({:ok, _none}), do: "gluetun reports no forwarded port"
  defp forward_error({:error, {:http_status, status}}), do: "gluetun answered #{status}"
  defp forward_error({:error, reason}) when is_binary(reason), do: reason
  defp forward_error(other), do: inspect(other)

  @doc false
  # The first IPv4 address of the tunnel interface, from `ip -4 -o addr show`.
  def read_tunnel_ip(interface) do
    case Mydia.BoundedCommand.run("ip", ["-4", "-o", "addr", "show", "dev", interface], 5_000) do
      {:ok, output} -> parse_tunnel_ip(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def parse_tunnel_ip(output) do
    with [_, addr] <- Regex.run(~r/\binet (\d+\.\d+\.\d+\.\d+)\//, output),
         {:ok, _} <- :inet.parse_address(String.to_charlist(addr)) do
      {:ok, addr}
    else
      _ -> {:error, :no_tunnel_address}
    end
  end

  defp down(state, reason) do
    state = put_vpn(state, {:down, reason})
    call_engine(state, {:stop, reason})
    %{state | verified: nil, last_port: nil}
  end

  # An engine that does not answer must not crash the gate: the next poll
  # repeats the call, since engine calls are idempotent.
  defp call_engine(state, message) do
    case state.engine_fun.(message) do
      :ok -> :ok
      other -> Logger.warning("Engine #{inspect(message)} returned #{inspect(other)}")
    end
  catch
    :exit, reason ->
      Logger.error("Engine #{inspect(message)} failed: #{inspect(reason)}")
      :error
  end

  defp put_vpn(%{last_vpn: value} = state, value), do: state

  defp put_vpn(state, value) do
    with {:down, reason} <- value do
      Logger.error("VPN down, torrents stopped: #{Status.describe(reason)}")
    end

    Status.put(state.status, :vpn, value)
    %{state | last_vpn: value}
  end

  # A forwarded port is identified by its number alone; `since` records when
  # that number was first seen and survives repeated polls.
  defp put_port(%{last_port: {:forwarded, n, _}} = state, {:forwarded, n}), do: state
  defp put_port(%{last_port: {:static, n}} = state, {:static, n}), do: state
  defp put_port(%{last_port: {:failed, r, n}} = state, {:failed, r, n}), do: state

  defp put_port(state, {:forwarded, n}) do
    value = {:forwarded, n, DateTime.utc_now()}
    Status.put(state.status, :port, value)
    %{state | last_port: value}
  end

  defp put_port(state, value) do
    Status.put(state.status, :port, value)
    %{state | last_port: value}
  end

  defp preflight(dir) do
    case File.read(Path.join(dir, "preflight")) do
      {:ok, body} ->
        cond do
          body =~ "net_admin=missing" -> {:down, :missing_net_admin}
          body =~ "tun=missing" -> {:down, :missing_tun}
          body =~ "split_group=missing" -> {:down, :split_group_missing}
          true -> :ok
        end

      {:error, _} ->
        {:down, :vpn_unreachable}
    end
  end

  defp client(state) do
    case File.read(Path.join(state.config.gluetun_dir, "apikey")) do
      {:ok, key} -> {:ok, GluetunClient.new(state.base_url, String.trim(key))}
      {:error, _} -> {:down, unreachable_reason(state.config.gluetun_dir)}
    end
  end

  defp status(req, state) do
    case GluetunClient.vpn_status(req) do
      {:ok, "running"} = ok -> ok
      {:ok, _other} -> {:down, last_error(state.config.gluetun_dir, :vpn_down)}
      {:error, _} -> {:down, unreachable_reason(state.config.gluetun_dir)}
    end
  end

  # Bad gluetun settings make it exit before its control server listens, so
  # an unreachable gluetun usually has the explanation at the end of its log.
  defp unreachable_reason(dir), do: last_error(dir, :vpn_unreachable)

  @log_tail_bytes 65_536

  # The last ERROR line in the tail of gluetun.log, which the entrypoint
  # rotates only between gluetun restarts, so it can still be large.
  defp last_error(dir, fallback) do
    with {:ok, tail} <- read_tail(Path.join(dir, "gluetun.log"), @log_tail_bytes),
         line when is_binary(line) <-
           tail |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.find(&(&1 =~ "ERROR")) do
      {:vpn_down, strip_timestamp(line)}
    else
      _ -> fallback
    end
  end

  # gluetun stamps every line (`2026-11-04T19:52:12Z ERROR ...`). Left in the
  # reason, a restart loop repeating one error would look like a new
  # transition on every poll.
  defp strip_timestamp(line) do
    line
    |> String.trim()
    |> String.replace(
      ~r/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?\s*/,
      ""
    )
  end

  defp read_tail(path, bytes) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, {:ok, data}} <-
           File.open(path, [:read, :binary], &:file.pread(&1, max(size - bytes, 0), bytes)) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  defp default_engine_fun(engine) do
    fn
      {:start, port, listen_ip} -> Engine.start_engine(engine, port, listen_ip)
      {:stop, reason} -> Engine.stop_engine(engine, reason)
    end
  end
end
