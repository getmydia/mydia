defmodule MydiaWeb.DevicesLive.Components do
  @moduledoc """
  Components for the user-facing devices page.

  Sibling-scoped to `MydiaWeb.DevicesLive.Index` and never globally imported.
  """
  use MydiaWeb, :html

  alias Mydia.RemoteAccess

  attr :devices, :list, required: true
  attr :show_all_devices, :boolean, default: false
  attr :show_clear_inactive_modal, :boolean, default: false
  attr :show_revoke_modal, :boolean, default: false
  attr :selected_device, :map, default: nil
  attr :show_delete_modal, :boolean, default: false
  attr :device_to_delete, :map, default: nil

  def device_list(assigns) do
    ~H"""
    <div id="device-list" class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <% device_count = length(@devices)
        visible_devices = if @show_all_devices, do: @devices, else: Enum.take(@devices, 10)
        hidden_count = device_count - length(visible_devices)

        inactive_devices =
          Enum.reject(@devices, fn d ->
            recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
          end)

        inactive_count = length(inactive_devices) %>
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title text-lg flex items-center gap-2">
            <.icon name="hero-device-phone-mobile" class="w-5 h-5" /> Your devices
            <span class="badge badge-ghost badge-sm">{device_count}</span>
          </h2>
          <%= if inactive_count > 0 do %>
            <button
              id="clear-inactive-devices"
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
              <h4 class="font-medium text-base-content/70">No devices connected</h4>
              <p class="text-sm text-base-content/50 max-w-xs">
                Use a pairing code above to connect your first player.
              </p>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
            <%= for device <- visible_devices do %>
              <div
                id={"device-#{device.id}"}
                class={[
                  "group card bg-base-200 transition-all duration-200",
                  if(RemoteAccess.RemoteDevice.revoked?(device),
                    do: "opacity-60",
                    else: "hover:bg-base-300/50"
                  )
                ]}
              >
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

                    <%!-- Actions --%>
                    <div class="flex items-center gap-1">
                      <%= if is_nil(device.revoked_at) do %>
                        <button
                          id={"revoke-device-#{device.id}"}
                          class="btn btn-ghost btn-xs btn-square text-warning opacity-50 group-hover:opacity-100"
                          title="Revoke access"
                          phx-click="open_revoke_modal"
                          phx-value-id={device.id}
                        >
                          <.icon name="hero-no-symbol" class="w-4 h-4" />
                        </button>
                      <% end %>
                      <button
                        id={"delete-device-#{device.id}"}
                        class="btn btn-ghost btn-xs btn-square text-error opacity-50 group-hover:opacity-100"
                        title="Remove device"
                        phx-click="open_delete_modal"
                        phx-value-id={device.id}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
          <%= if hidden_count > 0 do %>
            <button class="btn btn-ghost btn-sm w-full gap-2" phx-click="toggle_show_all_devices">
              <.icon name="hero-chevron-down" class="w-4 h-4" />
              Show {hidden_count} more device{if hidden_count == 1, do: "", else: "s"}
            </button>
          <% end %>
          <%= if @show_all_devices && device_count > 10 do %>
            <button class="btn btn-ghost btn-sm w-full gap-2" phx-click="toggle_show_all_devices">
              <.icon name="hero-chevron-up" class="w-4 h-4" /> Show less
            </button>
          <% end %>
        <% end %>
      </div>

      <%!-- Revoke Device Modal --%>
      <%= if @show_revoke_modal && @selected_device do %>
        <div class="modal modal-open" id="revoke-modal">
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
              <button id="confirm-revoke" phx-click="submit_revoke" class="btn btn-warning">
                Revoke
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_revoke_modal"></div>
        </div>
      <% end %>

      <%!-- Delete Device Modal --%>
      <%= if @show_delete_modal && @device_to_delete do %>
        <div class="modal modal-open" id="delete-modal">
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
              <button id="confirm-delete" phx-click="submit_delete" class="btn btn-error">
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
        <div class="modal modal-open" id="clear-inactive-modal">
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
              <button phx-click="close_clear_inactive_modal" class="btn btn-ghost">
                Cancel
              </button>
              <button
                id="confirm-clear-inactive"
                phx-click="submit_clear_inactive"
                class="btn btn-error"
              >
                Clear All
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_clear_inactive_modal"></div>
        </div>
      <% end %>
    </div>
    """
  end

  # Consider a device "active" (online now) if seen within the last 10 minutes.
  @active_threshold_seconds 600

  @doc """
  Whether a device was seen recently enough to count as online.

  Public because `MydiaWeb.DevicesLive.Index` decides which devices the
  clear-inactive action sweeps, and both sides must agree on "inactive".
  """
  @spec recent_activity?(DateTime.t() | nil) :: boolean()
  def recent_activity?(nil), do: false

  def recent_activity?(last_seen) do
    threshold = DateTime.utc_now() |> DateTime.add(-@active_threshold_seconds, :second)
    DateTime.compare(last_seen, threshold) == :gt
  end

  @doc """
  Renders a count with its noun, pluralizing the noun. Returns "1 device" or "3 devices".
  """
  @spec pluralize(non_neg_integer(), String.t()) :: String.t()
  def pluralize(1, word), do: "1 #{word}"
  def pluralize(n, word), do: "#{n} #{word}s"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
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
end
