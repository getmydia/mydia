defmodule MydiaWeb.DevicesLive.Components do
  @moduledoc """
  Components for the user-facing devices page.

  Sibling-scoped to `MydiaWeb.DevicesLive.Index` and never globally imported.
  """
  use MydiaWeb, :html

  alias Mydia.RemoteAccess

  attr :display, Mydia.TimeDisplay, required: true
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
            RemoteAccess.online?(d.last_seen_at) && is_nil(d.revoked_at)
          end)

        inactive_count = length(inactive_devices) %>
        <div class="flex items-center justify-between mb-4">
          <h2 class="card-title text-lg flex items-center gap-2">
            <.icon name="hero-device-phone-mobile" class="w-5 h-5" /> {gettext("Your devices")}
            <span class="badge badge-ghost badge-sm">{device_count}</span>
          </h2>
          <%= if inactive_count > 0 do %>
            <button
              id="clear-inactive-devices"
              class="btn btn-ghost btn-xs text-base-content/60"
              phx-click="open_clear_inactive_modal"
            >
              <.icon name="hero-trash" class="w-3 h-3" /> {gettext("Clear inactive (%{count})",
                count: inactive_count
              )}
            </button>
          <% end %>
        </div>

        <%= if @devices == [] do %>
          <div class="card bg-base-200">
            <div class="card-body items-center text-center py-8">
              <div class="w-16 h-16 rounded-full bg-base-300 flex items-center justify-center mb-2">
                <.icon name="hero-device-phone-mobile" class="w-8 h-8 opacity-40" />
              </div>
              <h4 class="font-medium text-base-content/70">{gettext("No devices connected")}</h4>
              <p class="text-sm text-base-content/50 max-w-xs">
                {gettext("Use a pairing code above to connect your first player.")}
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
                        RemoteAccess.online?(device.last_seen_at) -> "bg-success/10 text-success"
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
                          <span class="badge badge-error badge-xs">{gettext("Revoked")}</span>
                        <% else %>
                          <%= if RemoteAccess.online?(device.last_seen_at) do %>
                            <span class="w-1.5 h-1.5 rounded-full bg-success animate-pulse shrink-0"></span>
                          <% end %>
                        <% end %>
                      </div>
                      <div class="text-xs text-base-content/50 truncate">
                        <%= cond do %>
                          <% RemoteAccess.RemoteDevice.revoked?(device) -> %>
                            {gettext("Access revoked")}
                          <% RemoteAccess.online?(device.last_seen_at) -> %>
                            {gettext("Online now")}
                          <% is_nil(device.last_seen_at) -> %>
                            {gettext("Never connected")}
                          <% true -> %>
                            {format_relative_time(device.last_seen_at, @display)}
                        <% end %>
                      </div>
                    </div>

                    <%!-- Actions --%>
                    <div class="flex items-center gap-1">
                      <%= if is_nil(device.revoked_at) do %>
                        <button
                          id={"revoke-device-#{device.id}"}
                          class="btn btn-ghost btn-xs btn-square text-warning opacity-50 group-hover:opacity-100"
                          title={gettext("Revoke access")}
                          phx-click="open_revoke_modal"
                          phx-value-id={device.id}
                        >
                          <.icon name="hero-no-symbol" class="w-4 h-4" />
                        </button>
                      <% end %>
                      <button
                        id={"delete-device-#{device.id}"}
                        class="btn btn-ghost btn-xs btn-square text-error opacity-50 group-hover:opacity-100"
                        title={gettext("Remove device")}
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
              {ngettext("Show %{count} more device", "Show %{count} more devices", hidden_count)}
            </button>
          <% end %>
          <%= if @show_all_devices && device_count > 10 do %>
            <button class="btn btn-ghost btn-sm w-full gap-2" phx-click="toggle_show_all_devices">
              <.icon name="hero-chevron-up" class="w-4 h-4" /> {gettext("Show less")}
            </button>
          <% end %>
        <% end %>
      </div>

      <%!-- Device modals. `<.modal>` is a native <dialog>, so escape-to-close and
      focus handling come from the platform rather than being hand-rolled. --%>
      <.modal
        id="revoke-modal"
        show={@show_revoke_modal && @selected_device != nil}
        on_cancel={JS.push("close_revoke_modal")}
      >
        <:title>{gettext("Revoke Access?")}</:title>
        <p :if={@selected_device} class="text-base-content/70">
          {gettext(
            "%{device} will be disconnected and won't be able to access your library until paired again.",
            device: @selected_device.device_name
          )}
        </p>
        <:actions>
          <button phx-click="close_revoke_modal" class="btn btn-ghost">{gettext("Cancel")}</button>
          <button id="confirm-revoke" phx-click="submit_revoke" class="btn btn-warning">
            {gettext("Revoke")}
          </button>
        </:actions>
      </.modal>

      <.modal
        id="delete-modal"
        show={@show_delete_modal && @device_to_delete != nil}
        on_cancel={JS.push("close_delete_modal")}
      >
        <:title>{gettext("Remove Device?")}</:title>
        <p :if={@device_to_delete} class="text-base-content/70">
          {gettext("%{device} will be removed. You'll need to pair it again to reconnect.",
            device: @device_to_delete.device_name
          )}
        </p>
        <:actions>
          <button phx-click="close_delete_modal" class="btn btn-ghost">{gettext("Cancel")}</button>
          <button id="confirm-delete" phx-click="submit_delete" class="btn btn-error">
            {gettext("Remove")}
          </button>
        </:actions>
      </.modal>

      <% inactive_to_clear =
        Enum.reject(@devices, fn d ->
          RemoteAccess.online?(d.last_seen_at) && is_nil(d.revoked_at)
        end) %>
      <.modal
        id="clear-inactive-modal"
        show={@show_clear_inactive_modal}
        on_cancel={JS.push("close_clear_inactive_modal")}
      >
        <:title>{gettext("Clear Inactive Devices?")}</:title>
        <p class="text-base-content/70 mb-3">
          {ngettext(
            "This will remove %{count} inactive device. It will need to be paired again to reconnect.",
            "This will remove %{count} inactive devices. They will need to be paired again to reconnect.",
            length(inactive_to_clear)
          )}
        </p>
        <div class="text-sm text-base-content/50 max-h-32 overflow-y-auto">
          <div :for={device <- inactive_to_clear} class="flex items-center gap-2 py-1">
            <.icon name={platform_icon(device.platform)} class="w-3 h-3 opacity-60" />
            <span class="truncate">{device.device_name}</span>
          </div>
        </div>
        <:actions>
          <button phx-click="close_clear_inactive_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button id="confirm-clear-inactive" phx-click="submit_clear_inactive" class="btn btn-error">
            {gettext("Clear All")}
          </button>
        </:actions>
      </.modal>
    </div>
    """
  end

  # mydia.dev/download/<platform> resolves the newest release asset per platform
  # and redirects ios to TestFlight and flatpak to the flatpakrepo. Linking it
  # rather than resolving assets here keeps the release naming scheme in one
  # place, next to release.yml, where drift gets caught.
  @downloads [
    %{id: "android", icon: "hero-device-phone-mobile"},
    %{id: "ios", icon: "hero-device-phone-mobile"},
    %{id: "macos", icon: "hero-computer-desktop"},
    %{id: "windows", icon: "hero-computer-desktop"},
    %{id: "flatpak", icon: "hero-computer-desktop"},
    %{id: "linux", icon: "hero-archive-box"}
  ]

  defp download_name("android"), do: "Android"
  defp download_name("ios"), do: "iOS"
  defp download_name("macos"), do: "macOS"
  defp download_name("windows"), do: "Windows"
  defp download_name("flatpak"), do: "Linux"
  defp download_name("linux"), do: gettext("Linux tarball")

  defp download_label("android"), do: gettext("Download APK")
  defp download_label("ios"), do: gettext("Join the TestFlight beta")
  defp download_label("macos"), do: gettext("Download .dmg")
  defp download_label("windows"), do: gettext("Download installer")
  defp download_label("flatpak"), do: gettext("Get the Flatpak repo")
  defp download_label("linux"), do: gettext("Download .tar.gz")

  attr :hide_player, :boolean,
    default: false,
    doc: "when true, omit the browser player tile from the download list"

  def download_card(assigns) do
    assigns = assign(assigns, :downloads, @downloads)

    ~H"""
    <div id="download-card" class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-lg mb-1">
          <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> {gettext("Get the app")}
        </h2>
        <p class="text-base-content/70 mb-4">
          {gettext("Install the Mydia player, then connect it with a pairing code above.")}
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <a
            :for={platform <- @downloads}
            id={"download-#{platform.id}"}
            href={"https://mydia.dev/download/#{platform.id}"}
            target="_blank"
            rel="noopener"
            class="flex items-center gap-3 p-4 rounded-box border border-base-300 hover:border-primary/40 hover:shadow-md transition-all"
          >
            <div class="w-10 h-10 rounded-lg bg-base-200 flex items-center justify-center shrink-0">
              <.icon name={platform.icon} class="w-5 h-5" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-semibold truncate">{download_name(platform.id)}</div>
              <div class="text-xs text-base-content/50 truncate">
                {download_label(platform.id)}
              </div>
            </div>
            <.icon
              name="hero-arrow-top-right-on-square"
              class="w-4 h-4 text-base-content/30 shrink-0"
            />
          </a>

          <.link
            :if={!@hide_player}
            id="download-web"
            navigate={~p"/player"}
            class="flex items-center gap-3 p-4 rounded-box border border-base-300 hover:border-primary/40 hover:shadow-md transition-all"
          >
            <div class="w-10 h-10 rounded-lg bg-base-200 flex items-center justify-center shrink-0">
              <.icon name="hero-globe-alt" class="w-5 h-5" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-semibold truncate">{gettext("Web")}</div>
              <div class="text-xs text-base-content/50 truncate">
                {gettext("Play in this browser")}
              </div>
            </div>
            <.icon name="hero-chevron-right" class="w-4 h-4 text-base-content/30 shrink-0" />
          </.link>
        </div>

        <p class="text-xs text-base-content/50 mt-4">
          {gettext("Downloads are served from mydia.dev, so this device needs internet access.")}
        </p>
      </div>
    </div>
    """
  end

  defp format_datetime(%DateTime{} = dt, display) do
    format(dt, :datetime, display)
  end

  defp platform_icon("ios"), do: "hero-device-phone-mobile"
  defp platform_icon("android"), do: "hero-device-phone-mobile"
  defp platform_icon("web"), do: "hero-computer-desktop"
  defp platform_icon(_), do: "hero-device-tablet"

  defp format_relative_time(%DateTime{} = dt, display) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, dt, :second)

    cond do
      diff_seconds < 60 ->
        gettext("just now")

      diff_seconds < 3600 ->
        ngettext("%{count} min ago", "%{count} min ago", div(diff_seconds, 60))

      diff_seconds < 86400 ->
        ngettext("%{count} hour ago", "%{count} hours ago", div(diff_seconds, 3600))

      diff_seconds < 604_800 ->
        ngettext("%{count} day ago", "%{count} days ago", div(diff_seconds, 86400))

      true ->
        format_datetime(dt, display)
    end
  end
end
