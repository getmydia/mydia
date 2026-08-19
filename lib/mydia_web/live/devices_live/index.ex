defmodule MydiaWeb.DevicesLive.Index do
  @moduledoc """
  Players paired to this account, and where to download more.

  Pairing is a user's own action, so this page carries no role gate beyond
  authentication. A paired device receives a JWT minted for its owner, so it
  inherits exactly that user's permissions and pairing confers nothing.
  """
  use MydiaWeb, :live_view

  alias Mydia.RemoteAccess
  alias MydiaWeb.DevicesLive.Components

  require Logger

  # Online badges are derived from last_seen_at, which moves while the page sits
  # open. Without a timer the list shows whatever was true at mount.
  @refresh_interval_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)
     |> assign(:show_all_devices, false)
     |> assign(:show_clear_inactive_modal, false)
     |> load_devices()}
  end

  @impl true
  def handle_info(:refresh_devices, socket) do
    schedule_refresh()
    {:noreply, load_devices(socket)}
  end

  @impl true
  def handle_event("open_revoke_modal", %{"id" => id}, socket) do
    device = owned_device(socket, id)

    {:noreply,
     socket
     |> assign(:show_revoke_modal, device != nil)
     |> assign(:selected_device, device)}
  end

  def handle_event("close_revoke_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)}
  end

  def handle_event("submit_revoke", _params, socket) do
    case RemoteAccess.revoke_device(socket.assigns.selected_device) do
      {:ok, _device} ->
        {:noreply,
         socket
         |> assign(:show_revoke_modal, false)
         |> assign(:selected_device, nil)
         |> put_flash(:info, "Device revoked.")
         |> load_devices()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke device")}
    end
  end

  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    device = owned_device(socket, id)

    {:noreply,
     socket
     |> assign(:show_delete_modal, device != nil)
     |> assign(:device_to_delete, device)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)}
  end

  def handle_event("submit_delete", _params, socket) do
    case RemoteAccess.delete_device(socket.assigns.device_to_delete) do
      {:ok, _device} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:device_to_delete, nil)
         |> put_flash(:info, "Device removed.")
         |> load_devices()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to remove device")}
    end
  end

  def handle_event("open_clear_inactive_modal", _params, socket) do
    {:noreply, assign(socket, :show_clear_inactive_modal, true)}
  end

  def handle_event("close_clear_inactive_modal", _params, socket) do
    {:noreply, assign(socket, :show_clear_inactive_modal, false)}
  end

  def handle_event("submit_clear_inactive", _params, socket) do
    deleted =
      socket.assigns.devices
      |> Enum.reject(fn d ->
        Components.recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
      end)
      |> Enum.count(fn device -> match?({:ok, _}, RemoteAccess.delete_device(device)) end)

    {:noreply,
     socket
     |> assign(:show_clear_inactive_modal, false)
     |> put_flash(:info, "Removed #{Components.pluralize(deleted, "inactive device")}.")
     |> load_devices()}
  end

  def handle_event("toggle_show_all_devices", _params, socket) do
    {:noreply, assign(socket, :show_all_devices, !socket.assigns.show_all_devices)}
  end

  ## Private helpers

  # Every device action is addressed by an id from the client, so it is resolved
  # against this user's own list rather than fetched by id. Otherwise any user
  # could revoke any device by guessing a UUID. An id that is not in the list
  # returns nil, which leaves the modal closed rather than crashing the LiveView.
  defp owned_device(socket, id) do
    Enum.find(socket.assigns.devices, fn device -> device.id == id end)
  end

  defp load_devices(socket) do
    assign(socket, :devices, RemoteAccess.list_devices(socket.assigns.current_user.id))
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_devices, @refresh_interval_ms)
  end
end
