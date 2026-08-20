defmodule MydiaWeb.DevicesLive.PairingComponents do
  @moduledoc """
  The pairing card and its QR/claim-code modal.

  Split from `MydiaWeb.DevicesLive.Components` to keep each file to one
  sub-domain: this one is about connecting a new player, that one about
  managing the players already connected.
  """
  use MydiaWeb, :html

  require Logger

  # Mirrors the claim lifetime in Mydia.RemoteAccess.generate_claim_code/1. The
  # countdown ring is a percentage of this, so a literal divisor here would go
  # wrong the moment that TTL changed.
  @claim_lifetime_seconds 300

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
          <button
            type="button"
            id="pair-device-button"
            class="group flex w-full items-center gap-3 p-4 text-left bg-gradient-to-br from-primary/5 via-base-200 to-secondary/5 rounded-xl border border-primary/20 cursor-pointer hover:border-primary/40 hover:shadow-lg hover:shadow-primary/5 transition-all"
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
          </button>
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

      <.modal
        id="pairing-modal"
        show={@show_pairing_modal}
        on_cancel={JS.push("close_pairing_modal")}
      >
        <:title>
          <span class="flex items-center gap-3">
            <span class="w-10 h-10 rounded-xl bg-primary/10 flex items-center justify-center">
              <.icon name="hero-device-phone-mobile" class="w-5 h-5 text-primary" />
            </span>
            <span>
              <span class="block text-lg font-semibold">Pair a new device</span>
              <span class="block text-sm font-normal text-base-content/50">
                Open the Mydia app to connect
              </span>
            </span>
          </span>
        </:title>
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
                  style={"--value:#{countdown_percent(@countdown_seconds)}; --size:2.5rem; --thickness:3px;"}
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
      </.modal>
    </div>
    """
  end

  # Whole numbers only: `/` yields a float, which renders as
  # `--value:99.66666666666667` in the style attribute.
  defp countdown_percent(seconds) when seconds <= 0, do: 0

  defp countdown_percent(seconds) do
    min(100, round(seconds / @claim_lifetime_seconds * 100))
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

      encode_qr_svg(content)
    else
      nil
    end
  end

  # A node_addr carrying many candidate addresses can push the payload past what
  # a QR code holds, and EQRCode raises rather than returning an error. The modal
  # still shows the claim code, so falling back to nil costs the QR and nothing
  # else, where raising would take down the whole LiveView.
  defp encode_qr_svg(content) do
    content
    |> EQRCode.encode()
    |> EQRCode.svg(width: 180)
  rescue
    error ->
      Logger.warning("Could not render pairing QR code: #{Exception.message(error)}")
      nil
  end
end
