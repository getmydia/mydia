defmodule MydiaWeb.AdminRemoteAccessLive.Components do
  @moduledoc """
  Function components for the remote access admin page.
  """
  use MydiaWeb, :html

  alias Mydia.RemoteAccess

  attr :ra_config, :map, required: true
  attr :p2p_status, :map, required: true
  attr :devices, :list, required: true
  attr :claim_code, :string
  attr :claim_code_rendezvous_status, :atom, default: nil
  attr :claim_expires_at, :any
  attr :countdown_seconds, :integer, default: 0
  attr :pairing_error, :string
  attr :show_revoke_modal, :boolean, default: false
  attr :selected_device, :map
  attr :show_delete_modal, :boolean, default: false
  attr :device_to_delete, :map
  attr :show_pairing_modal, :boolean, default: false
  attr :show_add_url_modal, :boolean, default: false
  attr :new_url, :string, default: ""
  attr :show_advanced, :boolean, default: false
  attr :show_all_devices, :boolean, default: false
  attr :show_clear_inactive_modal, :boolean, default: false

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
        <%!-- Pairing & Status Row --%>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <%!-- Pair New Device Card --%>
          <%= if @pairing_available do %>
            <div
              class="group flex items-center gap-3 p-4 bg-gradient-to-br from-primary/5 via-base-200 to-secondary/5 rounded-xl border border-primary/20 cursor-pointer hover:border-primary/40 hover:shadow-lg hover:shadow-primary/5 transition-all"
              phx-click="open_pairing_modal"
            >
              <div class="w-11 h-11 rounded-xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center shadow-md group-hover:scale-105 transition-transform">
                <.icon name="hero-qr-code" class="w-5 h-5 text-primary-content" />
              </div>
              <div class="flex-1">
                <div class="font-semibold group-hover:text-primary transition-colors">
                  Pair New Device
                </div>
                <div class="text-xs text-base-content/50">
                  Scan QR or enter code
                </div>
              </div>
              <.icon
                name="hero-chevron-right"
                class="w-5 h-5 text-base-content/30 group-hover:text-primary group-hover:translate-x-0.5 transition-all"
              />
            </div>
          <% else %>
            <div class="flex items-center gap-3 p-4 bg-base-200 rounded-xl border border-base-300 opacity-60">
              <div class="w-11 h-11 rounded-xl bg-base-300 flex items-center justify-center">
                <.icon name="hero-qr-code" class="w-5 h-5 opacity-40" />
              </div>
              <div class="flex-1">
                <div class="font-semibold">Pair New Device</div>
                <div class="text-xs text-base-content/50">
                  <%= if @p2p_running do %>
                    Waiting for relay connection...
                  <% else %>
                    Starting P2P...
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

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
                  onclick={"navigator.clipboard.writeText('#{@p2p_status.node_id}')"}
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

        <%!-- Devices Section --%>
        <% device_count = length(@devices)
        visible_devices = if @show_all_devices, do: @devices, else: Enum.take(@devices, 10)
        hidden_count = device_count - length(visible_devices)

        inactive_devices =
          Enum.reject(@devices, fn d ->
            recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
          end)

        inactive_count = length(inactive_devices) %>
        <div class="space-y-4">
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
              <.icon name="hero-device-phone-mobile" class="w-4 h-4" /> Paired Devices
              <span class="badge badge-ghost badge-sm">{device_count}</span>
            </h3>
            <%= if inactive_count > 0 do %>
              <button
                class="btn btn-ghost btn-xs text-base-content/60"
                phx-click="open_clear_inactive_modal"
              >
                <.icon name="hero-trash" class="w-3 h-3" /> Clear inactive ({inactive_count})
              </button>
            <% end %>
          </div>

          <%= if @devices == [] do %>
            <div class="card bg-base-200">
              <div class="card-body items-center text-center py-8">
                <div class="w-16 h-16 rounded-full bg-base-300 flex items-center justify-center mb-2">
                  <.icon name="hero-device-phone-mobile" class="w-8 h-8 opacity-40" />
                </div>
                <h4 class="font-medium text-base-content/70">No Devices Paired</h4>
                <p class="text-sm text-base-content/50 max-w-xs">
                  Generate a pairing code above to connect your first device.
                </p>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
              <%= for device <- visible_devices do %>
                <div class={[
                  "group card bg-base-200 transition-all duration-200",
                  if(RemoteAccess.RemoteDevice.revoked?(device),
                    do: "opacity-60",
                    else: "hover:bg-base-300/50"
                  )
                ]}>
                  <div class="card-body p-3">
                    <div class="flex items-center gap-3">
                      <%!-- Device Icon --%>
                      <div class={[
                        "w-9 h-9 rounded-lg flex items-center justify-center shrink-0",
                        cond do
                          RemoteAccess.RemoteDevice.revoked?(device) -> "bg-error/10 text-error"
                          recent_activity?(device.last_seen_at) -> "bg-success/10 text-success"
                          true -> "bg-base-300 text-base-content/50"
                        end
                      ]}>
                        <.icon name={platform_icon(device.platform)} class="w-5 h-5" />
                      </div>

                      <%!-- Device Info --%>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-1.5">
                          <span class="font-medium text-sm truncate">{device.device_name}</span>
                          <%= if RemoteAccess.RemoteDevice.revoked?(device) do %>
                            <span class="badge badge-error badge-xs">Revoked</span>
                          <% else %>
                            <%= if recent_activity?(device.last_seen_at) do %>
                              <span class="w-1.5 h-1.5 rounded-full bg-success animate-pulse shrink-0"></span>
                            <% end %>
                          <% end %>
                        </div>
                        <div class="text-xs text-base-content/50 truncate">
                          <%= cond do %>
                            <% RemoteAccess.RemoteDevice.revoked?(device) -> %>
                              Access revoked
                            <% recent_activity?(device.last_seen_at) -> %>
                              Online now
                            <% is_nil(device.last_seen_at) -> %>
                              Never connected
                            <% true -> %>
                              {format_relative_time(device.last_seen_at)}
                          <% end %>
                        </div>
                      </div>

                      <%!-- Actions dropdown --%>
                      <div class="dropdown dropdown-end">
                        <div
                          tabindex="0"
                          role="button"
                          class="btn btn-ghost btn-xs btn-square opacity-50 group-hover:opacity-100"
                        >
                          <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
                        </div>
                        <ul
                          tabindex="0"
                          class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-1 shadow-lg border border-base-300"
                        >
                          <%= if is_nil(device.revoked_at) do %>
                            <li>
                              <button
                                class="text-warning"
                                phx-click="open_revoke_modal"
                                phx-value-id={device.id}
                              >
                                <.icon name="hero-no-symbol" class="w-4 h-4" /> Revoke
                              </button>
                            </li>
                          <% end %>
                          <li>
                            <button
                              class="text-error"
                              phx-click="open_delete_modal"
                              phx-value-id={device.id}
                            >
                              <.icon name="hero-trash" class="w-4 h-4" /> Remove
                            </button>
                          </li>
                        </ul>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
            <%= if hidden_count > 0 do %>
              <button
                class="btn btn-ghost btn-sm w-full gap-2"
                phx-click="toggle_show_all_devices"
              >
                <.icon name="hero-chevron-down" class="w-4 h-4" />
                Show {hidden_count} more device{if hidden_count == 1, do: "", else: "s"}
              </button>
            <% end %>
            <%= if @show_all_devices && device_count > 10 do %>
              <button
                class="btn btn-ghost btn-sm w-full gap-2"
                phx-click="toggle_show_all_devices"
              >
                <.icon name="hero-chevron-up" class="w-4 h-4" /> Show less
              </button>
            <% end %>
          <% end %>
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

      <%!-- Revoke Device Modal --%>
      <%= if @show_revoke_modal && @selected_device do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Revoke Access?</h3>
            <p class="text-base-content/70">
              <strong>{@selected_device.device_name}</strong>
              will be disconnected and won't be able to access your library until paired again.
            </p>
            <div class="modal-action">
              <button phx-click="close_revoke_modal" class="btn btn-ghost">
                Cancel
              </button>
              <button phx-click="submit_revoke" class="btn btn-warning">
                Revoke
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_revoke_modal"></div>
        </div>
      <% end %>

      <%!-- Delete Device Modal --%>
      <%= if @show_delete_modal && @device_to_delete do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Remove Device?</h3>
            <p class="text-base-content/70">
              <strong>{@device_to_delete.device_name}</strong>
              will be removed. You'll need to pair it again to reconnect.
            </p>
            <div class="modal-action">
              <button phx-click="close_delete_modal" class="btn btn-ghost">
                Cancel
              </button>
              <button phx-click="submit_delete" class="btn btn-error">
                Remove
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_delete_modal"></div>
        </div>
      <% end %>

      <%!-- Clear Inactive Devices Modal --%>
      <%= if @show_clear_inactive_modal do %>
        <% inactive_to_clear =
          Enum.reject(@devices, fn d ->
            recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
          end) %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Clear Inactive Devices?</h3>
            <p class="text-base-content/70 mb-3">
              This will remove <strong>{length(inactive_to_clear)}</strong>
              inactive device{if length(inactive_to_clear) == 1, do: "", else: "s"}.
              They will need to be paired again to reconnect.
            </p>
            <div class="text-sm text-base-content/50 max-h-32 overflow-y-auto">
              <%= for device <- inactive_to_clear do %>
                <div class="flex items-center gap-2 py-1">
                  <.icon name={platform_icon(device.platform)} class="w-3 h-3 opacity-60" />
                  <span class="truncate">{device.device_name}</span>
                </div>
              <% end %>
            </div>
            <div class="modal-action">
              <button
                phx-click="close_clear_inactive_modal"
                class="btn btn-ghost"
              >
                Cancel
              </button>
              <button phx-click="submit_clear_inactive" class="btn btn-error">
                Clear All
              </button>
            </div>
          </div>
          <div
            class="modal-backdrop"
            phx-click="close_clear_inactive_modal"
          >
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

      <%!-- Pair New Device Modal --%>
      <%= if @show_pairing_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-md shadow-2xl">
            <%!-- Header --%>
            <div class="flex items-center justify-between mb-2">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-xl bg-primary/10 flex items-center justify-center">
                  <.icon name="hero-device-phone-mobile" class="w-5 h-5 text-primary" />
                </div>
                <div>
                  <h3 class="text-lg font-semibold">Pair New Device</h3>
                  <p class="text-sm text-base-content/50">Open the Mydia app to connect</p>
                </div>
              </div>
              <button
                class="btn btn-sm btn-circle btn-ghost"
                phx-click="close_pairing_modal"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <%= if @claim_code do %>
              <%!-- Active pairing code --%>
              <div class="space-y-5 pt-4">
                <%!-- QR pairing never needs the relay, so it remains available. --%>
                <% qr_svg = generate_qr_code(@ra_config, @p2p_status, @claim_code) %>
                <%= if qr_svg do %>
                  <div class="flex flex-col items-center gap-2">
                    <div class="p-3 bg-white rounded-xl shadow-md">
                      {Phoenix.HTML.raw(qr_svg)}
                    </div>
                    <div class="flex flex-col items-center gap-1">
                      <span class="text-xs text-base-content/40">QR Contents</span>
                      <div class="flex flex-wrap justify-center gap-1.5">
                        <div class="tooltip" data-tip="Instance ID">
                          <span class="badge badge-sm badge-ghost gap-1 font-mono">
                            <.icon name="hero-server" class="w-3 h-3 opacity-50" />
                            {String.slice(@ra_config.instance_id, 0..7)}
                          </span>
                        </div>
                        <%= if @p2p_status && @p2p_status.node_id do %>
                          <div class="tooltip" data-tip="Node ID (for P2P discovery)">
                            <span class="badge badge-sm badge-ghost gap-1 font-mono">
                              <.icon name="hero-signal" class="w-3 h-3 opacity-50" />
                              {String.slice(@p2p_status.node_id, 0..7)}
                            </span>
                          </div>
                        <% end %>
                        <div class="tooltip" data-tip="Claim Code (see below)">
                          <span class="badge badge-sm badge-ghost gap-1">
                            <.icon name="hero-ticket" class="w-3 h-3 opacity-50" /> Claim Code
                          </span>
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%!-- Divider - only show when registered --%>
                <%= if @claim_code_rendezvous_status == :registered do %>
                  <div class="flex items-center gap-3">
                    <div class="flex-1 h-px bg-base-300"></div>
                    <span class="text-xs text-base-content/40 uppercase tracking-wider">
                      or enter code
                    </span>
                    <div class="flex-1 h-px bg-base-300"></div>
                  </div>
                <% end %>

                <%!-- Pairing Code --%>
                <div class="text-center">
                  <div class="inline-flex items-center gap-2 bg-base-200 rounded-xl px-5 py-3">
                    <code class="text-2xl font-bold tracking-[0.25em] font-mono">
                      {@claim_code}
                    </code>
                    <button
                      class="btn btn-ghost btn-sm btn-square"
                      phx-click="copy_claim_code"
                      onclick={"navigator.clipboard.writeText('#{@claim_code}')"}
                      title="Copy code"
                    >
                      <.icon name="hero-clipboard-document" class="w-4 h-4 opacity-50" />
                    </button>
                  </div>
                  <div
                    :if={@claim_code_rendezvous_status == :registered}
                    class="mt-2 flex items-center justify-center gap-1.5 text-xs"
                  >
                    <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
                    <span class="text-success">Ready for pairing</span>
                  </div>
                  <div
                    :if={@claim_code_rendezvous_status == :unregistered}
                    id="pairing-relay-warning"
                    class="alert alert-warning mt-3"
                  >
                    <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                    <span class="text-sm">
                      The relay could not be reached, so typing this code will not work.
                      Scan the QR code instead, or try again in a moment.
                    </span>
                  </div>
                </div>

                <%!-- Countdown & Regenerate --%>
                <div class="flex items-center justify-center gap-4">
                  <div class="flex items-center gap-3">
                    <div
                      class={[
                        "radial-progress text-xs",
                        if(@countdown_seconds > 60, do: "text-success", else: "text-warning")
                      ]}
                      style={"--value:#{min(100, @countdown_seconds / 3)}; --size:2.5rem; --thickness:3px;"}
                      role="progressbar"
                    >
                      <.icon name="hero-clock" class="w-4 h-4" />
                    </div>
                    <div class="text-sm">
                      <span class="text-base-content/60">Expires in</span>
                      <span class={[
                        "font-mono font-semibold ml-1",
                        if(@countdown_seconds > 60, do: "text-base-content", else: "text-warning")
                      ]}>
                        {format_countdown(@countdown_seconds)}
                      </span>
                    </div>
                  </div>
                  <span class="text-base-content/20">•</span>
                  <button
                    id="regenerate-pairing-code-btn"
                    class="link link-hover text-sm text-base-content/60"
                    phx-click="generate_claim_code"
                    phx-disable-with="..."
                  >
                    New Code
                  </button>
                </div>
              </div>
            <% else %>
              <%!-- Error or loading state --%>
              <div class="text-center py-8 space-y-4">
                <%= if @pairing_error do %>
                  <div class="alert alert-error text-left text-sm">
                    <.icon name="hero-exclamation-circle" class="w-4 h-4" />
                    <span>{@pairing_error}</span>
                  </div>
                <% end %>

                <div class="flex justify-center">
                  <span class="loading loading-spinner loading-lg text-primary/50"></span>
                </div>
                <p class="text-sm text-base-content/50">Generating pairing code...</p>
              </div>
            <% end %>
          </div>
          <div
            class="modal-backdrop bg-base-300/60 backdrop-blur-sm"
            phx-click="close_pairing_modal"
          >
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  ## Helper functions used by the template

  defp format_countdown(seconds) when seconds <= 0, do: "Expired"

  defp format_countdown(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
  end

  # Consider a device "active" (online now) if seen within the last 10 minutes.
  @active_threshold_seconds 600

  defp recent_activity?(nil), do: false

  defp recent_activity?(last_seen) do
    threshold = DateTime.utc_now() |> DateTime.add(-@active_threshold_seconds, :second)
    DateTime.compare(last_seen, threshold) == :gt
  end

  defp platform_icon("ios"), do: "hero-device-phone-mobile"
  defp platform_icon("android"), do: "hero-device-phone-mobile"
  defp platform_icon("web"), do: "hero-computer-desktop"
  defp platform_icon(_), do: "hero-device-tablet"

  defp format_relative_time(nil), do: "never"

  defp format_relative_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} min ago"
      diff_seconds < 86400 -> "#{pluralize(div(diff_seconds, 3600), "hour")} ago"
      diff_seconds < 604_800 -> "#{pluralize(div(diff_seconds, 86400), "day")} ago"
      true -> format_datetime(dt)
    end
  end

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(n, word), do: "#{n} #{word}s"

  defp generate_qr_code(config, p2p_status, claim_code) do
    if config && claim_code do
      content =
        Jason.encode!(%{
          instance_id: config.instance_id,
          node_addr: p2p_status && p2p_status.node_addr,
          claim_code: claim_code
        })

      qr_code = EQRCode.encode(content)
      EQRCode.svg(qr_code, width: 180)
    else
      nil
    end
  end

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
