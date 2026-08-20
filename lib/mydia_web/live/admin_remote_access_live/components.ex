defmodule MydiaWeb.AdminRemoteAccessLive.Components do
  @moduledoc """
  Function components for the remote access admin page.
  """
  use MydiaWeb, :html

  attr :ra_config, :map, required: true
  attr :p2p_status, :map, required: true
  attr :show_add_url_modal, :boolean, default: false
  attr :new_url, :string, default: ""
  attr :show_advanced, :boolean, default: false

  def remote_access_panel(assigns) do
    # Check if P2P is running
    p2p_running =
      assigns.ra_config && assigns.ra_config.enabled && assigns.p2p_status &&
        assigns.p2p_status.running

    # Pairing requires relay to be connected (so we can produce a node_addr)
    pairing_available = p2p_running && assigns.p2p_status.relay_connected

    # Get local address info
    local_addr = get_local_address()

    # Get auto-detected URLs (public + local)
    detected_urls = get_detected_urls()

    assigns =
      assigns
      |> assign(:p2p_running, p2p_running)
      |> assign(:pairing_available, pairing_available)
      |> assign(:local_addr, local_addr)
      |> assign(:detected_urls, detected_urls)

    ~H"""
    <div class="p-4 sm:p-6 space-y-5">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-xl flex items-center justify-center transition-colors",
            if(@ra_config && @ra_config.enabled && @pairing_available,
              do: "bg-success/15",
              else: "bg-base-300"
            )
          ]}>
            <.icon
              name="hero-signal"
              class={"w-5 h-5 #{if @ra_config && @ra_config.enabled && @pairing_available, do: "text-success", else: "opacity-50"}"}
            />
          </div>
          <div>
            <h2 class="font-semibold">Player Remote Access</h2>
            <p class="text-xs text-base-content/50">
              <%= cond do %>
                <% !(@ra_config && @ra_config.enabled) -> %>
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
        <input
          type="checkbox"
          id="remote-access-toggle"
          class="toggle toggle-success"
          checked={@ra_config && @ra_config.enabled}
          phx-click="toggle_remote_access"
          phx-value-enabled={to_string(!(@ra_config && @ra_config.enabled))}
        />
      </div>

      <%= if @ra_config && @ra_config.enabled do %>
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
                  class="text-xs text-base-content/30 hover:text-purple-500 transition-colors shrink-0"
                  title="P2P powered by iroh"
                >
                  iroh
                </a>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Direct URLs Card --%>
        <div class="card bg-base-200">
          <div class="card-body p-4 gap-3">
            <div class="flex items-center justify-between">
              <h4 class="card-title text-sm gap-2">
                <.icon name="hero-link" class="w-4 h-4 opacity-60" /> Direct URLs
              </h4>
              <button
                class="btn btn-sm btn-ghost gap-1"
                phx-click="open_add_url_modal"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add URL
              </button>
            </div>

            <p class="text-xs text-base-content/60 -mt-1">
              Direct URLs allow the app to bypass the relay when on the same network for faster streaming.
            </p>

            <div class="grid gap-4 sm:grid-cols-2 mt-1">
              <%!-- Manual URLs Section --%>
              <div class="space-y-2">
                <div class="flex items-center gap-2">
                  <.icon name="hero-pencil-square" class="w-3.5 h-3.5 opacity-50" />
                  <span class="text-xs font-medium text-base-content/70">Manual URLs</span>
                  <%= if @ra_config.direct_urls && @ra_config.direct_urls != [] do %>
                    <span class="badge badge-ghost badge-xs">{length(@ra_config.direct_urls)}</span>
                  <% end %>
                </div>

                <%= if @ra_config.direct_urls && @ra_config.direct_urls != [] do %>
                  <div class="space-y-1.5">
                    <%= for url <- @ra_config.direct_urls do %>
                      <div class="flex items-center gap-2 bg-base-300/50 rounded-lg px-3 py-2 group">
                        <.icon name="hero-link" class="w-3.5 h-3.5 opacity-40 shrink-0" />
                        <code class="font-mono text-xs truncate flex-1">{url}</code>
                        <button
                          class="btn btn-xs btn-ghost btn-square opacity-50 group-hover:opacity-100 hover:btn-error"
                          phx-click="remove_direct_url"
                          phx-value-url={url}
                          title="Remove URL"
                        >
                          <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 text-xs text-base-content/50 italic bg-base-300/30 rounded-lg px-3 py-3">
                    <.icon name="hero-plus-circle" class="w-4 h-4 opacity-40" />
                    <span>Click "Add URL" to add custom addresses</span>
                  </div>
                <% end %>
              </div>

              <%!-- Auto-detected URLs Section --%>
              <div class="space-y-2">
                <div class="flex items-center gap-2">
                  <.icon name="hero-signal" class="w-3.5 h-3.5 opacity-50" />
                  <span class="text-xs font-medium text-base-content/70">Auto-detected</span>
                  <%= if @detected_urls != [] do %>
                    <span class="badge badge-ghost badge-xs">{length(@detected_urls)}</span>
                  <% end %>
                </div>

                <%= if @detected_urls != [] do %>
                  <div class="space-y-1.5">
                    <%= for url <- @detected_urls do %>
                      <div class="flex items-center gap-2 bg-base-300/30 rounded-lg px-3 py-2 border border-dashed border-base-300">
                        <.icon name="hero-signal" class="w-3.5 h-3.5 opacity-40 shrink-0" />
                        <code class="font-mono text-xs truncate flex-1 text-base-content/70">
                          {url}
                        </code>
                        <span class="badge badge-xs badge-ghost">Auto</span>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 text-xs text-base-content/50 italic bg-base-300/30 rounded-lg px-3 py-3">
                    <.icon name="hero-exclamation-circle" class="w-4 h-4 opacity-40" />
                    <span>No URLs detected. Check network config.</span>
                  </div>
                <% end %>
              </div>
            </div>

            <div class="divider my-1"></div>

            <div class="alert bg-info/10 border-info/20 py-2.5">
              <.icon name="hero-light-bulb" class="w-5 h-5 text-info" />
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
                <code class="bg-info/20 px-1.5 py-0.5 rounded font-mono text-info">
                  http://mydia.tail1234.ts.net:4000
                </code>
              </div>
            </div>
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

      <%!-- Add Direct URL Modal --%>
      <%= if @show_add_url_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Add Direct URL</h3>
            <p class="text-sm text-base-content/70 mb-4">
              Add a URL where your server can be reached directly (e.g., on the same network).
            </p>
            <.form
              for={%{}}
              as={:direct_url}
              id="add-direct-url-form"
              phx-change="update_new_url"
              phx-submit="add_direct_url"
            >
              <input
                type="url"
                name="url"
                placeholder="https://mydia.local:4000"
                class="input input-bordered w-full"
                value={@new_url}
              />
              <div class="modal-action">
                <button
                  type="button"
                  phx-click="close_add_url_modal"
                  class="btn btn-ghost"
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary" disabled={@new_url == ""}>
                  Add
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_add_url_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end

  ## Helper functions used by the template

  defp get_local_address do
    config = Application.get_env(:mydia, :direct_urls, [])
    port = Keyword.get(config, :external_port, 4000)

    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        ip =
          interfaces
          |> Enum.flat_map(fn {_iface, props} ->
            props
            |> Enum.filter(fn {key, _} -> key == :addr end)
            |> Enum.map(fn {:addr, addr} -> addr end)
            |> Enum.filter(&valid_local_ip?/1)
          end)
          |> List.first()

        case ip do
          {a, b, c, d} -> %{ip: "#{a}.#{b}.#{c}.#{d}", port: port}
          _ -> %{ip: nil, port: port}
        end

      {:error, _} ->
        %{ip: nil, port: port}
    end
  end

  defp get_detected_urls do
    public_urls = Mydia.RemoteAccess.DirectUrls.detect_public_urls()
    local_urls = Mydia.RemoteAccess.DirectUrls.detect_local_urls()

    (public_urls ++ local_urls)
    |> Enum.uniq()
  end

  defp valid_local_ip?({127, _, _, _}), do: false
  defp valid_local_ip?({169, 254, _, _}), do: false
  defp valid_local_ip?({172, 17, _, _}), do: false

  defp valid_local_ip?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
              tuple_size({a, b, c, d}) == 4,
       do: true

  defp valid_local_ip?(_), do: false

  defp display_relay_url(nil), do: "(connecting...)"
  defp display_relay_url(url), do: url

  defp connection_type_label("direct"), do: "Direct"
  defp connection_type_label("relay"), do: "Relay"
  defp connection_type_label("mixed"), do: "Mixed"
  defp connection_type_label(_), do: nil

  defp connection_type_class("direct"), do: "text-success font-medium"
  defp connection_type_class("relay"), do: "text-warning font-medium"
  defp connection_type_class("mixed"), do: "text-info font-medium"
  defp connection_type_class(_), do: ""
end
