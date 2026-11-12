defmodule Mydia.Downloads.BuiltIn.Status do
  @moduledoc """
  The built-in torrent client's combined state: engine, VPN and listen port.

  Every change is broadcast so the admin page updates live. The `Rqbit`
  adapter and `ClientHealth` read `blocking_reason/1`, so a stopped engine
  surfaces as a named reason instead of a connection timeout.
  """

  use Agent

  @topic "built_in_torrent:status"

  defstruct engine: :starting, vpn: :off, port: nil, warnings: [], topic: @topic

  @type t :: %__MODULE__{}

  def topic, do: @topic

  # opts: :name, :warnings (Config.warnings, shown on the admin panel) and :topic
  # (the PubSub topic broadcasts go to; tests pass a unique one so async tests
  # do not hear each other).
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    warnings = Keyword.get(opts, :warnings, [])
    topic = Keyword.get(opts, :topic, @topic)
    Agent.start_link(fn -> %__MODULE__{warnings: warnings, topic: topic} end, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @spec get(GenServer.server()) :: t()
  def get(server \\ __MODULE__), do: Agent.get(server, & &1)

  @spec put(GenServer.server(), :engine | :vpn | :port | :warnings, term()) :: :ok
  # Broadcasts from inside the Agent, so subscribers receive updates in the
  # order they were applied even when several processes write at once.
  def put(server \\ __MODULE__, part, value) do
    Agent.update(server, fn status ->
      status = Map.put(status, part, value)
      Phoenix.PubSub.broadcast(Mydia.PubSub, status.topic, {:built_in_status, status})
      status
    end)
  end

  @spec blocking_reason(t()) :: nil | term()
  # The VPN clause comes first: Vpn records the tunnel as down before it stops
  # the engine, and in between the engine still reads :running.
  def blocking_reason(%__MODULE__{vpn: {:down, reason}}), do: reason
  # :connecting is written before the engine is stopped, so it blocks too.
  def blocking_reason(%__MODULE__{vpn: :connecting}), do: :vpn_connecting
  def blocking_reason(%__MODULE__{engine: :running}), do: nil
  def blocking_reason(%__MODULE__{engine: {:stopped, reason}}), do: reason
  def blocking_reason(%__MODULE__{engine: {:crashed, reason, _}}), do: reason
  def blocking_reason(%__MODULE__{engine: :disabled}), do: :engine_disabled
  def blocking_reason(%__MODULE__{}), do: :engine_starting

  @spec describe(term()) :: String.t()
  def describe(:missing_net_admin),
    do: "The VPN needs the NET_ADMIN capability. Add cap_add: [NET_ADMIN] to the Mydia container."

  def describe(:missing_tun),
    do: "The VPN needs the TUN device. Add devices: [/dev/net/tun] to the Mydia container."

  def describe(:split_group_missing),
    do:
      "The torrent group the VPN relies on (mydia-torrent) is missing or collides with PGID. Recreate the container, or pick another PGID."

  def describe({:reserved_variable, name}),
    do: "MYDIA_VPN_#{name} is set by Mydia itself. Remove it from the container environment."

  def describe({:reserved_name_taken}),
    do:
      "Another download client is named \"Built-in\", a name reserved for the built-in torrent client, so the built-in client was not enabled. Rename that client (Admin, Download Clients, or its DOWNLOAD_CLIENT_<N>_NAME), then save the built-in client's settings again."

  def describe({:invalid_port, value}),
    do: "MYDIA_TORRENT_PORT is #{inspect(value)}, not a port number. Using 51413."

  def describe({:invalid_api_port, value}),
    do: "MYDIA_TORRENT_API_PORT is #{inspect(value)}, not a port number. Using 3030."

  def describe({:invalid_enabled, value}),
    do:
      "MYDIA_TORRENT_ENABLED is #{inspect(value)}, which is neither true nor false. Ignoring it and deciding automatically."

  def describe({:vpn_auth_failed, message}),
    do: "The VPN provider rejected the login: #{message}. Check the MYDIA_VPN_ credentials."

  def describe(:vpn_down), do: "The VPN tunnel is down. Torrents are stopped until it returns."

  def describe({:vpn_down, last_log}),
    do: "The VPN tunnel is down. Torrents are stopped until it returns. Last VPN log: #{last_log}"

  def describe(:vpn_connecting),
    do: "The VPN tunnel is connecting. Torrents start once it is verified."

  def describe({:vpn_settings_write_failed, posix}),
    do:
      "Could not write the VPN settings file (#{:file.format_error(posix)}). The VPN keeps its previous settings."

  def describe({:vpn_settings_rejected, keys}),
    do:
      "The VPN service ignored settings Mydia wrote: #{Enum.join(keys, ", ")}. The container image and Mydia may be out of step; recreate the container."

  def describe(:vpn_apply_timeout),
    do:
      "The VPN service did not pick up the new settings within 30 seconds. Torrents are stopped until it does."

  def describe(:vpn_applying),
    do: "Applying the new VPN settings. Torrents start once the tunnel is verified."

  def describe(:vpn_unreachable),
    do: "The VPN service is not answering. Torrents are stopped until it does."

  def describe(:leak_detected),
    do:
      "Torrent traffic was not going through the VPN. Torrents will not start until the VPN is fixed."

  def describe({:leak_check_failed, message}),
    do:
      "Could not confirm torrent traffic goes through the VPN (#{message}). Torrents are stopped."

  def describe({:port_forward_failed, message}),
    do:
      "Port forwarding failed (#{message}). Torrents keep running on the last port; seeding is limited to outgoing connections."

  def describe({:engine_exit, code}), do: "The torrent engine exited with code #{code}."
  def describe(:engine_starting), do: "The torrent engine is starting."
  def describe(:engine_disabled), do: "The built-in torrent client is disabled."

  def describe(:rqbit_not_found),
    do: "The rqbit binary is missing from this installation."

  def describe({:spawn_failed, message}),
    do:
      "The rqbit binary could not be started (#{message}). Check that it is installed and executable."

  def describe({:path_unwritable, path, reason, variable}),
    do:
      "Cannot write to #{path} (#{:file.format_error(reason)}). Make it writable, or set #{variable} to a writable directory."

  def describe({:start_failed, reason}),
    do:
      "The built-in torrent client failed to start (#{start_failure(reason)}). Mydia retries automatically; saving its settings again retries at once."

  def describe(other), do: "Built-in torrent client error: #{inspect(other)}"

  # Peels the supervisor's wrapping off down to the child that failed.
  defp start_failure({:shutdown, {:failed_to_start_child, child, reason}}),
    do: "#{inspect(child)}: #{start_failure(reason)}"

  defp start_failure(reason), do: inspect(reason)
end
