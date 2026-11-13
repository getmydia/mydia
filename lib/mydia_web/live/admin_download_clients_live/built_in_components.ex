defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Downloads.BuiltIn.VpnProviders

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
      <div class="card-body gap-4 p-4">
        <div class="flex flex-wrap items-center gap-3">
          <div class="rounded-box bg-primary/10 text-primary p-2 shrink-0">
            <.icon name="hero-arrow-down-tray" class="size-5 block" />
          </div>
          <h3 class="font-semibold">{gettext("Built-in torrent client")}</h3>
          <.state_badge running?={@running?} status={@status} />
          <span
            :if={@running? && @vpn?}
            id="built-in-vpn-experimental"
            class="badge badge-sm badge-warning badge-soft"
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
          <div id="built-in-off-reason" role="status" class="alert alert-soft">
            <.icon name="hero-information-circle" class="size-5 shrink-0" />
            <span class="text-sm">{off_reason_label(@off_reason)}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :running?, :boolean, required: true
  attr :status, Status, default: nil

  defp state_badge(assigns) do
    {tone, label} =
      cond do
        !assigns.running? -> {:neutral, gettext("Off")}
        is_nil(assigns.status) -> {:warning, gettext("Unknown")}
        true -> {engine_tone(assigns.status.engine), engine_short(assigns.status.engine)}
      end

    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <span id="built-in-state-badge" class={["badge badge-sm badge-soft gap-1.5", badge_class(@tone)]}>
      <span aria-hidden="true" class={["status status-xs", status_class(@tone)]} />
      {@label}
    </span>
    """
  end

  attr :status, Status, default: nil
  attr :vpn?, :boolean, required: true
  attr :display, Mydia.TimeDisplay, required: true

  defp running_state(assigns) do
    ~H"""
    <div
      :if={is_nil(@status)}
      id="built-in-status-unavailable"
      role="alert"
      class="alert alert-warning alert-soft"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <span class="text-sm">
        {gettext("Status unavailable: the built-in torrent client's status could not be read.")}
      </span>
    </div>
    <div
      :if={@status}
      id="built-in-status"
      class="stats stats-vertical md:stats-horizontal md:auto-cols-fr w-full bg-base-100 border border-base-300"
    >
      <.stat_tile
        id="built-in-engine-state"
        icon="hero-cpu-chip"
        label={gettext("Engine")}
        tone={engine_tone(@status.engine)}
        tile={engine_tile(@status.engine)}
      />
      <.stat_tile
        :if={@vpn?}
        id="built-in-vpn-state"
        icon="hero-shield-check"
        label={gettext("VPN")}
        tone={vpn_tone(@status.vpn)}
        tile={vpn_tile(@status.vpn)}
      />
      <.stat_tile
        id="built-in-port-state"
        icon="hero-arrows-right-left"
        label={gettext("Port")}
        tone={port_tone(@status.port)}
        tile={port_tile(@status.port, @display)}
      />
    </div>
    <div
      :if={@status && @status.warnings != []}
      id="built-in-warnings"
      role="alert"
      class="alert alert-warning alert-soft items-start"
    >
      <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
      <ul class="text-sm space-y-1">
        <li :for={warning <- @status.warnings}>{Status.describe(warning)}</li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :atom, required: true, values: [:success, :warning, :error, :neutral]
  attr :tile, :any, required: true, doc: "{value, description or nil}"

  defp stat_tile(assigns) do
    {value, desc} = assigns.tile
    assigns = assign(assigns, value: value, desc: desc)

    ~H"""
    <div id={@id} class="stat gap-y-1 min-w-0">
      <div class={["stat-figure rounded-full p-2.5", figure_class(@tone)]}>
        <.icon name={@icon} class="size-6 block" />
      </div>
      <div class="stat-title">{@label}</div>
      <div class="stat-value text-xl whitespace-normal break-words">{@value}</div>
      <div :if={@desc} class="stat-desc whitespace-normal break-words">{@desc}</div>
    </div>
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

  ## Tiles: {value, description}

  defp engine_tile(:running), do: {gettext("Running"), nil}
  defp engine_tile(:starting), do: {gettext("Starting"), nil}
  defp engine_tile(:disabled), do: {gettext("Disabled"), nil}
  defp engine_tile({:stopped, reason}), do: {gettext("Stopped"), Status.describe(reason)}
  defp engine_tile({:crashed, reason, 0}), do: {gettext("Not running"), Status.describe(reason)}

  defp engine_tile({:crashed, reason, restarts}),
    do: {gettext("Crashed after %{n} restarts", n: restarts), Status.describe(reason)}

  defp engine_short({:crashed, _, 0}), do: gettext("Not running")
  defp engine_short({:crashed, _, _}), do: gettext("Crashed")
  defp engine_short(engine), do: engine |> engine_tile() |> elem(0)

  defp vpn_tile(:off), do: {gettext("Off"), nil}
  defp vpn_tile(:connecting), do: {gettext("Connecting"), nil}

  defp vpn_tile({:up, %{provider: provider, public_ip: ip}}),
    do:
      {gettext("Connected"),
       gettext("via %{provider}, public IP %{ip}",
         provider: provider_label(provider),
         ip: ip || "?"
       )}

  defp vpn_tile({:down, reason}), do: {gettext("Down"), Status.describe(reason)}

  defp provider_label(name) do
    case VpnProviders.get(name) do
      %{label: label} -> label
      nil -> name || "?"
    end
  end

  defp port_tile(nil, _display), do: {gettext("Not set yet"), nil}
  defp port_tile({:static, n}, _display), do: {to_string(n), gettext("Fixed")}

  defp port_tile({:forwarded, n, since}, display),
    do:
      {to_string(n),
       gettext("Forwarded since %{since}",
         since: MydiaWeb.DateTimeFormat.format(since, :time, display)
       )}

  defp port_tile({:failed, reason, last}, _display),
    do: {if(last, do: to_string(last), else: "-"), Status.describe(reason)}

  ## Tones

  defp engine_tone(:running), do: :success
  defp engine_tone(:starting), do: :warning
  defp engine_tone(:disabled), do: :neutral
  defp engine_tone(_stopped_or_crashed), do: :error

  defp vpn_tone({:up, _}), do: :success
  defp vpn_tone(:connecting), do: :warning
  defp vpn_tone(:off), do: :neutral
  defp vpn_tone({:down, _}), do: :error

  defp port_tone(nil), do: :neutral
  defp port_tone({:failed, _, _}), do: :error
  defp port_tone(_static_or_forwarded), do: :success

  defp figure_class(:success), do: "bg-success/10 text-success"
  defp figure_class(:warning), do: "bg-warning/10 text-warning"
  defp figure_class(:error), do: "bg-error/10 text-error"
  defp figure_class(:neutral), do: "bg-base-content/5 text-base-content/50"

  defp badge_class(:success), do: "badge-success"
  defp badge_class(:warning), do: "badge-warning"
  defp badge_class(:error), do: "badge-error"
  defp badge_class(:neutral), do: nil

  defp status_class(:success), do: "status-success"
  defp status_class(:warning), do: "status-warning"
  defp status_class(:error), do: "status-error"
  defp status_class(:neutral), do: nil
end
