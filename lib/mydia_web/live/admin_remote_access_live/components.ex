defmodule MydiaWeb.AdminRemoteAccessLive.Components do
  @moduledoc """
  Function components for the remote access admin page.
  """
  use MydiaWeb, :html

  attr :ra_config, :map, required: true
  attr :p2p_status, :map, required: true
  attr :remote_access_setting, :boolean, required: true
  attr :remote_access_source, :atom, default: :default
  attr :remote_access_locked, :boolean, default: false

  def remote_access_panel(assigns) do
    # Check if P2P is running
    p2p_running =
      assigns.remote_access_setting && assigns.p2p_status && assigns.p2p_status.running

    # Pairing requires relay to be connected (so we can produce a node_addr)
    pairing_available = p2p_running && assigns.p2p_status.relay_connected

    # Get auto-detected URLs (public + local)
    detected_urls = get_detected_urls()

    assigns =
      assigns
      |> assign(:p2p_running, p2p_running)
      |> assign(:pairing_available, pairing_available)
      |> assign(:detected_urls, detected_urls)

    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-xl flex items-center justify-center transition-colors",
            if(@remote_access_setting && @pairing_available,
              do: "bg-success/15",
              else: "bg-base-300"
            )
          ]}>
            <.icon
              name="hero-signal"
              class={"w-5 h-5 #{if @remote_access_setting && @pairing_available, do: "text-success", else: "opacity-50"}"}
            />
          </div>
          <div>
            <div class="font-semibold">Allow player connections</div>
            <p class="text-xs text-base-content/50">
              <%= cond do %>
                <% !@remote_access_setting -> %>
                  Connect mobile apps from anywhere
                <% @pairing_available -> %>
                  Players can connect via P2P
                <% @p2p_running -> %>
                  Connecting to relay...
                <% true -> %>
                  Initializing...
              <% end %>
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <.config_source_badge source={@remote_access_source} size="xs" />
          <input
            type="checkbox"
            id="remote-access-toggle"
            class="toggle toggle-success"
            checked={@remote_access_setting}
            disabled={@remote_access_locked}
            phx-click="toggle_remote_access"
            phx-value-enabled={to_string(!@remote_access_setting)}
          />
        </div>
      </div>

      <p :if={@remote_access_locked} id="remote-access-env-note" class="text-xs text-base-content/60">
        Set by <code>ENABLE_REMOTE_ACCESS</code>. Remove the variable to change it here.
      </p>

      <%= if @remote_access_setting && @ra_config do %>
        <%!-- Status Row --%>
        <div class="space-y-3">
          <%!-- Status Card --%>
          <div class="flex flex-col gap-2 p-4 bg-base-200 rounded-xl border border-base-300">
            <div class="flex items-center gap-3">
              <div class={[
                "w-3 h-3 rounded-full shrink-0",
                cond do
                  @pairing_available -> "bg-success"
                  @p2p_running -> "bg-warning animate-pulse"
                  true -> "bg-warning animate-pulse"
                end
              ]}>
              </div>
              <div class="min-w-0 flex-1">
                <div class="font-medium text-sm">
                  <%= cond do %>
                    <% @pairing_available -> %>
                      P2P Online
                    <% @p2p_running -> %>
                      P2P Connecting...
                    <% true -> %>
                      P2P Starting...
                  <% end %>
                </div>
                <div class="text-xs text-base-content/50">
                  <%= if @p2p_status && @p2p_status.relay_connected do %>
                    <span class="text-success">Relay connected</span>
                  <% else %>
                    <span class="text-warning">Relay disconnected</span>
                  <% end %>
                  <%= if @p2p_status && @p2p_status.connected_peers > 0 do %>
                    <span class="mx-1">·</span>
                    <span>
                      {@p2p_status.connected_peers} device{if @p2p_status.connected_peers == 1,
                        do: "",
                        else: "s"} online
                    </span>
                    <%= if @p2p_status.peer_connection_type do %>
                      <span class="mx-1">·</span>
                      <span class={connection_type_class(@p2p_status.peer_connection_type)}>
                        {connection_type_label(@p2p_status.peer_connection_type)}
                      </span>
                    <% end %>
                  <% end %>
                </div>
              </div>

              <%!-- Node ID (subtle) --%>
              <%= if @p2p_status && @p2p_status.node_id do %>
                <button
                  class="hidden lg:flex items-center gap-1.5 text-xs text-base-content/40 hover:text-base-content/60 transition-colors"
                  phx-click="copy_peer_id"
                  data-node-id={@p2p_status.node_id}
                  onclick="navigator.clipboard?.writeText(this.dataset.nodeId)"
                  title={"Copy Node ID: #{@p2p_status.node_id}"}
                >
                  <code class="font-mono">{String.slice(@p2p_status.node_id, 0..7)}</code>
                  <.icon name="hero-clipboard-document" class="w-3 h-3" />
                </button>
              <% end %>

              <button
                class="btn btn-ghost btn-xs btn-square opacity-50 hover:opacity-100 shrink-0"
                phx-click="refresh_p2p"
                title="Refresh"
              >
                <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
              </button>
            </div>

            <%!-- Relay URL (subtle row) --%>
            <%= if @p2p_status do %>
              <div class="flex items-center gap-2 pt-1 border-t border-base-300/50 mt-1">
                <.icon name="hero-server-stack" class="w-3 h-3 text-base-content/40 shrink-0" />
                <span class="text-xs text-base-content/40">Relay:</span>
                <code class="text-xs font-mono text-base-content/50 truncate flex-1">
                  {display_relay_url(@p2p_status.relay_url)}
                </code>
                <a
                  href="https://www.iroh.computer/"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-xs text-base-content/30 hover:text-secondary transition-colors shrink-0"
                  title="P2P powered by iroh"
                >
                  iroh
                </a>
              </div>
            <% end %>
          </div>
        </div>

        <.admin_section
          id="direct-urls"
          title="Direct URLs"
          icon="hero-link"
          count={length(@ra_config.direct_urls || [])}
        >
          <:actions>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="new_direct_url">
              <.icon name="hero-plus" class="w-4 h-4" /> Add URL
            </button>
          </:actions>
          <p class="text-xs text-base-content/60">
            Direct URLs allow the app to bypass the relay when on the same network for faster streaming.
          </p>
          <.admin_list id="direct-urls-list" items={@ra_config.direct_urls || []}>
            <:row :let={url}>
              <.admin_row id={"direct-url-#{:erlang.phash2(url)}"}>
                <:title><code class="font-mono text-sm break-all">{url}</code></:title>
                <:actions>
                  <.row_actions>
                    <.row_action
                      icon="hero-trash"
                      title="Remove URL"
                      destructive
                      phx-click="delete_direct_url"
                      phx-value-url={url}
                    />
                  </.row_actions>
                </:actions>
              </.admin_row>
            </:row>
            <:empty>No manual URLs yet. Add one so the player can skip the relay.</:empty>
          </.admin_list>
        </.admin_section>

        <.admin_section
          id="detected-urls"
          title="Auto-detected URLs"
          icon="hero-signal"
          count={length(@detected_urls)}
        >
          <.admin_list id="detected-urls-list" items={@detected_urls}>
            <:row :let={url}>
              <.admin_row id={"detected-url-#{:erlang.phash2(url)}"}>
                <:title><code class="font-mono text-sm break-all">{url}</code></:title>
                <:badges><span class="badge badge-sm badge-outline">Auto</span></:badges>
              </.admin_row>
            </:row>
            <:empty>No URLs detected. Check the server's network configuration.</:empty>
          </.admin_list>
        </.admin_section>

        <div class="alert bg-info/10 border-info/20 py-2.5">
          <.icon name="hero-light-bulb" class="w-5 h-5 text-primary" />
          <div class="text-xs">
            <span class="font-semibold">Tip:</span>
            Use
            <a
              href="https://tailscale.com"
              target="_blank"
              rel="noopener"
              class="link link-info font-medium"
            >
              Tailscale
            </a>
            for secure access anywhere. Add your Tailscale address, e.g.
            <code class="bg-info/20 px-1.5 py-0.5 rounded font-mono text-primary">
              http://mydia.tail1234.ts.net:4000
            </code>
          </div>
        </div>
      <% else %>
        <%!-- Disabled state --%>
        <div class="alert">
          <.icon name="hero-device-phone-mobile" class="w-6 h-6 opacity-40" />
          <div>
            <div class="font-medium">Connect Players from Anywhere</div>
            <div class="text-sm opacity-70">
              Enable remote access so your phone and tablet can connect to this Mydia server.
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :direct_url, :string, default: ""

  def direct_url_modal(assigns) do
    ~H"""
    <.admin_modal
      id="direct-url-modal"
      icon="hero-link"
      title="Add direct URL"
      subtitle="Where this server can be reached directly, e.g. on the same network"
      on_close="close_direct_url_modal"
    >
      <.form
        for={%{}}
        as={:direct_url}
        id="direct-url-form"
        phx-change="validate_direct_url"
        phx-submit="save_direct_url"
      >
        <input
          type="url"
          name="url"
          placeholder="https://mydia.local:4000"
          class="input input-bordered w-full"
          value={@direct_url}
        />
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_direct_url_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary" disabled={@direct_url == ""}>Add</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  ## Helper functions used by the template

  defp get_detected_urls do
    public_urls = Mydia.RemoteAccess.DirectUrls.detect_public_urls()
    local_urls = Mydia.RemoteAccess.DirectUrls.detect_local_urls()

    (public_urls ++ local_urls)
    |> Enum.uniq()
  end

  defp display_relay_url(nil), do: "(connecting...)"
  defp display_relay_url(url), do: url

  defp connection_type_label("direct"), do: "Direct"
  defp connection_type_label("relay"), do: "Relay"
  defp connection_type_label("mixed"), do: "Mixed"
  defp connection_type_label(_), do: nil

  defp connection_type_class("direct"), do: "text-success font-medium"
  defp connection_type_class("relay"), do: "text-warning font-medium"
  defp connection_type_class("mixed"), do: "text-primary font-medium"
  defp connection_type_class(_), do: ""
end
