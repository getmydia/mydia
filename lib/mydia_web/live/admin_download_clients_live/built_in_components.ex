defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.BuiltIn.Status

  # The panel renders whether or not the client runs, so a user who runs an
  # external client can still find and turn on the built-in one.
  attr :running?, :boolean, required: true
  # nil when the status could not be read.
  attr :status, Status, default: nil
  attr :vpn?, :boolean, required: true
  attr :display, Mydia.TimeDisplay, required: true
  attr :off_reason, :any, default: nil, doc: "Settings.off_reason/2 when the client is off"
  attr :enable_locked?, :boolean, default: false, doc: "enabled comes from the environment"

  def built_in_panel(assigns) do
    ~H"""
    <div id="built-in-torrent" class="card bg-base-200 border border-base-300 mb-4">
      <div class="card-body gap-3 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <.icon name="hero-arrow-down-tray" class="size-5" />
          <h3 class="font-semibold">{gettext("Built-in torrent client")}</h3>
          <span :if={!@running?} class="badge badge-sm badge-ghost">{gettext("Off")}</span>
          <span
            :if={@running? && @vpn?}
            id="built-in-vpn-experimental"
            class="badge badge-sm badge-warning"
          >
            {gettext("VPN experimental")}
          </span>
          <div class="flex items-center gap-2 ml-auto">
            <button
              :if={@running? && @status && match?({:crashed, _, _}, @status.engine)}
              id="built-in-restart"
              type="button"
              class="btn btn-sm border-base-content/20"
              phx-click="restart_built_in"
            >
              <.icon name="hero-arrow-path" class="size-4" /> {gettext("Restart")}
            </button>
            <button
              :if={!@running? && !@enable_locked?}
              id="built-in-enable"
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="enable_built_in"
              phx-disable-with={gettext("Enabling...")}
            >
              <.icon name="hero-power" class="size-4" /> {gettext("Enable")}
            </button>
            <button
              id="built-in-configure"
              type="button"
              class="btn btn-sm border-base-content/20"
              phx-click="open_built_in_settings"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("Configure")}
            </button>
          </div>
        </div>
        <%= if @running? do %>
          <.running_state status={@status} vpn?={@vpn?} display={@display} />
        <% else %>
          <p id="built-in-off-reason" class="text-sm text-base-content/70">
            {off_reason_label(@off_reason)}
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :status, Status, default: nil
  attr :vpn?, :boolean, required: true
  attr :display, Mydia.TimeDisplay, required: true

  defp running_state(assigns) do
    ~H"""
    <p :if={is_nil(@status)} id="built-in-status-unavailable" class="text-sm text-warning">
      {gettext("Status unavailable: the built-in torrent client's status could not be read.")}
    </p>
    <dl :if={@status} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
      <dt class="text-base-content/70">{gettext("Engine")}</dt>
      <dd id="built-in-engine-state">{engine_label(@status.engine)}</dd>
      <%= if @vpn? do %>
        <dt class="text-base-content/70">{gettext("VPN")}</dt>
        <dd id="built-in-vpn-state">{vpn_label(@status.vpn)}</dd>
      <% end %>
      <dt class="text-base-content/70">{gettext("Port")}</dt>
      <dd id="built-in-port-state">{port_label(@status.port, @display)}</dd>
    </dl>
    <ul :if={@status && @status.warnings != []} id="built-in-warnings" class="text-sm text-warning">
      <li :for={warning <- @status.warnings}>{Status.describe(warning)}</li>
    </ul>
    """
  end

  @doc """
  What the container still has to grant the VPN, with the compose lines that
  grant it. These need the container recreated, so the form cannot fix them.
  """
  attr :preflight, :map, required: true, doc: "the map from Preflight.read/1"

  def vpn_setup_card(assigns) do
    ~H"""
    <div id="built-in-vpn-setup-card" role="alert" class="alert alert-warning items-start">
      <.icon name="hero-wrench-screwdriver" class="size-5 shrink-0 mt-0.5" />
      <div class="min-w-0 space-y-2">
        <p class="font-semibold">{gettext("The container needs a few settings first")}</p>
        <p class="text-sm">
          {gettext(
            "Add these lines to the Mydia service in your compose file, then recreate the container. The VPN can be switched on once they are in place."
          )}
        </p>
        <ul class="text-sm list-disc ms-5">
          <li :if={@preflight[:net_admin] == :missing}>{gettext("Missing: NET_ADMIN capability")}</li>
          <li :if={@preflight[:tun] == :missing}>{gettext("Missing: TUN device")}</li>
          <li :if={@preflight[:src_valid_mark] == :missing}>
            {gettext("Missing: src_valid_mark sysctl")}
          </li>
          <li :if={@preflight[:split_group] == :missing}>
            {gettext("Missing: the mydia-torrent group (pick another PGID)")}
          </li>
        </ul>
        <pre
          class="text-xs bg-base-100 text-base-content rounded-box p-3 whitespace-pre-wrap break-all"
          phx-no-curly-interpolation
        >cap_add: [NET_ADMIN]
    devices: [/dev/net/tun]
    sysctls: [net.ipv4.conf.all.src_valid_mark=1]</pre>
      </div>
    </div>
    """
  end

  defp off_reason_label(:automatic), do: gettext("Off: another download client is configured.")

  defp off_reason_label(:rqbit_missing),
    do: gettext("Off: rqbit is not installed on this system, so the built-in client cannot run.")

  defp off_reason_label(:env), do: gettext("Off: turned off by MYDIA_TORRENT_ENABLED.")
  defp off_reason_label(:ui), do: gettext("Off: turned off in these settings.")
  defp off_reason_label(:name_taken), do: Status.describe({:reserved_name_taken})

  defp off_reason_label({:start_failed, _} = reason),
    do: gettext("Off: %{why}", why: Status.describe(reason))

  defp off_reason_label(_), do: gettext("Off.")

  defp engine_label(:running), do: gettext("Running")
  defp engine_label(:starting), do: gettext("Starting")
  defp engine_label(:disabled), do: gettext("Disabled")

  defp engine_label({:stopped, reason}),
    do: gettext("Stopped: %{why}", why: Status.describe(reason))

  defp engine_label({:crashed, reason, 0}),
    do: gettext("Not running: %{why}", why: Status.describe(reason))

  defp engine_label({:crashed, reason, restarts}),
    do: gettext("Crashed after %{n} restarts: %{why}", n: restarts, why: Status.describe(reason))

  defp vpn_label(:off), do: gettext("Off")
  defp vpn_label(:connecting), do: gettext("Connecting")

  defp vpn_label({:up, %{provider: provider, public_ip: ip}}),
    do: gettext("Connected via %{provider}, public IP %{ip}", provider: provider, ip: ip || "?")

  defp vpn_label({:down, reason}), do: Status.describe(reason)

  defp port_label(nil, _display), do: gettext("Not set yet")
  defp port_label({:static, n}, _display), do: gettext("%{port} (fixed)", port: n)

  defp port_label({:forwarded, n, since}, display),
    do:
      gettext("%{port} (forwarded since %{since})",
        port: n,
        since: MydiaWeb.DateTimeFormat.format(since, :time, display)
      )

  defp port_label({:failed, reason, last}, _display),
    do: gettext("%{port}: %{why}", port: last, why: Status.describe(reason))
end
