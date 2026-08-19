defmodule MydiaWeb.DevicesLive.PairingComponents do
  @moduledoc """
  The pairing card and its QR/claim-code modal.

  Split from `MydiaWeb.DevicesLive.Components` to keep each file to one
  sub-domain: this one is about connecting a new player, that one about
  managing the players already connected.
  """
  use MydiaWeb, :html

  attr :ra_config, :map, default: nil
  attr :p2p_status, :map, default: nil
  attr :remote_access_enabled, :boolean, required: true
  attr :claim_code, :string, default: nil
  attr :claim_code_rendezvous_status, :any, default: nil
  attr :claim_expires_at, :any, default: nil
  attr :countdown_seconds, :integer, default: 0
  attr :pairing_error, :string, default: nil
  attr :show_pairing_modal, :boolean, default: false

  def pairing_card(assigns) do
    pairing_available =
      assigns.remote_access_enabled && assigns.p2p_status && assigns.p2p_status.running &&
        assigns.p2p_status.relay_connected

    assigns = assign(assigns, :pairing_available, pairing_available)

    ~H"""
    <div id="pairing-card" class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-lg mb-1">
          <.icon name="hero-qr-code" class="w-5 h-5" /> Connect a player
        </h2>
        <p class="text-base-content/70 mb-4">
          Open the Mydia app on your device and enter a pairing code.
        </p>

        <%= if @pairing_available do %>
          <div
            id="pair-device-button"
            class="group flex items-center gap-3 p-4 bg-gradient-to-br from-primary/5 via-base-200 to-secondary/5 rounded-xl border border-primary/20 cursor-pointer hover:border-primary/40 hover:shadow-lg hover:shadow-primary/5 transition-all"
            phx-click="open_pairing_modal"
          >
            <div class="w-11 h-11 rounded-xl bg-gradient-to-br from-primary to-secondary flex items-center justify-center shadow-md group-hover:scale-105 transition-transform">
              <.icon name="hero-qr-code" class="w-5 h-5 text-primary-content" />
            </div>
            <div class="flex-1">
              <div class="font-semibold group-hover:text-primary transition-colors">
                Pair a new device
              </div>
              <div class="text-xs text-base-content/50">
                Scan a QR code or type a short code
              </div>
            </div>
            <.icon
              name="hero-chevron-right"
              class="w-5 h-5 text-base-content/30 group-hover:text-primary group-hover:translate-x-0.5 transition-all"
            />
          </div>
        <% else %>
          <div
            id="pairing-disabled-notice"
            class="flex items-center gap-3 p-4 bg-base-200 rounded-xl border border-base-300"
          >
            <div class="w-11 h-11 rounded-xl bg-base-300 flex items-center justify-center shrink-0">
              <.icon name="hero-qr-code" class="w-5 h-5 opacity-40" />
            </div>
            <div class="flex-1">
              <div class="font-semibold">Pairing is unavailable</div>
              <div class="text-xs text-base-content/50">
                <%= if @remote_access_enabled do %>
                  Connecting to the relay. Try again in a moment.
                <% else %>
                  Remote access is turned off on this server. Ask an administrator to turn it on
                  before connecting a player.
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Pair New Device Modal --%>
      <%= if @show_pairing_modal do %>
        <div class="modal modal-open" id="pairing-modal">
          <div class="modal-box max-w-md shadow-2xl">
            <%!-- Header --%>
            <div class="flex items-center justify-between mb-2">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-xl bg-primary/10 flex items-center justify-center">
                  <.icon name="hero-device-phone-mobile" class="w-5 h-5 text-primary" />
                </div>
                <div>
                  <h3 class="text-lg font-semibold">Pair a new device</h3>
                  <p class="text-sm text-base-content/50">Open the Mydia app to connect</p>
                </div>
              </div>
              <button class="btn btn-sm btn-circle btn-ghost" phx-click="close_pairing_modal">
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <%= if @claim_code do %>
              <%!-- Active pairing code --%>
              <div class="space-y-5 pt-4">
                <%!-- QR Code - only show when registered on rendezvous --%>
                <%= if @claim_code_rendezvous_status == :registered do %>
                  <% qr_svg = generate_qr_code(@ra_config, @p2p_status, @claim_code) %>
                  <%= if qr_svg do %>
                    <div class="flex flex-col items-center gap-2">
                      <div class="p-3 bg-white rounded-xl shadow-md">
                        {Phoenix.HTML.raw(qr_svg)}
                      </div>
                    </div>
                  <% end %>

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
                  <%= if @claim_code_rendezvous_status == :registered do %>
                    <div class="inline-flex items-center gap-2 bg-base-200 rounded-xl px-5 py-3">
                      <code id="claim-code" class="text-2xl font-bold tracking-[0.25em] font-mono">
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
                    <div class="mt-2 flex items-center justify-center gap-1.5 text-xs">
                      <.icon name="hero-check-circle" class="w-4 h-4 text-success" />
                      <span class="text-success">Ready for pairing</span>
                    </div>
                  <% else %>
                    <div class="inline-flex flex-col items-center gap-3 bg-base-200 rounded-xl px-8 py-5">
                      <span class="loading loading-spinner loading-lg text-primary"></span>
                      <div class="text-sm text-base-content/60">Preparing pairing code...</div>
                    </div>
                  <% end %>
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
                  <div id="pairing-error" class="alert alert-error text-left text-sm">
                    <.icon name="hero-exclamation-circle" class="w-4 h-4" />
                    <span>{@pairing_error}</span>
                  </div>
                <% else %>
                  <div class="flex justify-center">
                    <span class="loading loading-spinner loading-lg text-primary/50"></span>
                  </div>
                  <p class="text-sm text-base-content/50">Generating pairing code...</p>
                <% end %>
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

  defp format_countdown(seconds) when seconds <= 0, do: "Expired"

  defp format_countdown(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

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
end
