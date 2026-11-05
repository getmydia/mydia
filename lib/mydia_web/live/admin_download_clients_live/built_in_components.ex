defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Downloads.BuiltIn.Status

  attr :status, Status, required: true
  attr :vpn?, :boolean, required: true
  attr :display, Mydia.TimeDisplay, required: true

  def built_in_panel(assigns) do
    ~H"""
    <div id="built-in-torrent" class="card bg-base-200 mb-4">
      <div class="card-body gap-3 p-4">
        <div class="flex items-center gap-2">
          <.icon name="hero-arrow-down-tray" class="size-5" />
          <h3 class="font-semibold">{gettext("Built-in torrent client")}</h3>
          <span :if={@vpn?} id="built-in-vpn-experimental" class="badge badge-sm badge-warning">
            {gettext("VPN experimental")}
          </span>
          <button
            id="built-in-restart"
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="restart_built_in"
          >
            <.icon name="hero-arrow-path" class="size-4" /> {gettext("Restart")}
          </button>
        </div>
        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
          <dt class="text-base-content/70">{gettext("Engine")}</dt>
          <dd id="built-in-engine-state">{engine_label(@status.engine)}</dd>
          <%= if @vpn? do %>
            <dt class="text-base-content/70">{gettext("VPN")}</dt>
            <dd id="built-in-vpn-state">{vpn_label(@status.vpn)}</dd>
          <% end %>
          <dt class="text-base-content/70">{gettext("Port")}</dt>
          <dd id="built-in-port-state">{port_label(@status.port, @display)}</dd>
        </dl>
        <ul :if={@status.warnings != []} id="built-in-warnings" class="text-sm text-warning">
          <li :for={warning <- @status.warnings}>{Status.describe(warning)}</li>
        </ul>
      </div>
    </div>
    """
  end

  defp engine_label(:running), do: gettext("Running")
  defp engine_label(:starting), do: gettext("Starting")
  defp engine_label(:disabled), do: gettext("Disabled")

  defp engine_label({:stopped, reason}),
    do: gettext("Stopped: %{why}", why: Status.describe(reason))

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
