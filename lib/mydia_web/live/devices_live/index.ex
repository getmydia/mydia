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
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)
     |> assign(:show_all_devices, false)
     |> assign(:show_clear_inactive_modal, false)
     |> assign(:claim_code, nil)
     |> assign(:claim_expires_at, nil)
     |> assign(:countdown_seconds, 0)
     |> assign(:claim_code_rendezvous_status, nil)
     |> assign(:pairing_error, nil)
     |> assign(:show_pairing_modal, false)
     |> assign(:remote_access_enabled, RemoteAccess.enabled?())
     |> assign(:ra_config, RemoteAccess.get_config())
     |> load_p2p_status()
     |> load_devices()}
  end

  @impl true
  def handle_info(:refresh_devices, socket) do
    schedule_refresh()
    {:noreply, socket |> load_p2p_status() |> load_devices()}
  end

  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :do_countdown_tick, 1000)
    {:noreply, socket}
  end

  def handle_info(:do_countdown_tick, socket) do
    {:noreply, handle_countdown_tick(socket)}
  end

  def handle_info({:claim_consumed, %{code: code, user_id: user_id}}, socket) do
    current_code = socket.assigns.claim_code

    socket =
      if user_id == socket.assigns.current_user.id && current_code &&
           normalize_code(current_code) == normalize_code(code) do
        socket
        |> assign(:claim_code, nil)
        |> assign(:claim_expires_at, nil)
        |> assign(:countdown_seconds, 0)
        |> assign(:show_pairing_modal, false)
        |> load_devices()
        |> put_flash(:info, "Device connected.")
      else
        socket
      end

    {:noreply, socket}
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

  def handle_event("open_pairing_modal", _params, socket) do
    socket = assign(socket, :show_pairing_modal, true)

    socket =
      if is_nil(socket.assigns.claim_code) do
        do_generate_claim_code(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("close_pairing_modal", _params, socket) do
    {:noreply, assign(socket, :show_pairing_modal, false)}
  end

  def handle_event("generate_claim_code", _params, socket) do
    {:noreply, do_generate_claim_code(socket)}
  end

  def handle_event("copy_claim_code", _params, socket) do
    {:noreply, put_flash(socket, :info, "Code copied to clipboard")}
  end

  ## Private helpers

  defp do_generate_claim_code(socket) do
    case RemoteAccess.generate_claim_code(socket.assigns.current_user.id) do
      {:ok, claim} ->
        send(self(), :countdown_tick)

        socket
        |> assign(:pairing_error, nil)
        |> assign(:claim_code, claim.code)
        |> assign(:claim_code_rendezvous_status, :registered)
        |> assign(:claim_expires_at, claim.expires_at)
        |> assign(:countdown_seconds, max(0, DateTime.diff(claim.expires_at, DateTime.utc_now())))

      {:error, :disabled} ->
        socket
        |> assign(:remote_access_enabled, false)
        |> assign(
          :pairing_error,
          "Remote access is turned off on this server. Ask an administrator to turn it on."
        )

      {:error, :p2p_not_running} ->
        assign(socket, :pairing_error, "P2P service is not running. Please try again.")

      {:error, :p2p_not_ready} ->
        assign(
          socket,
          :pairing_error,
          "P2P service is still starting up. Please try again in a moment."
        )

      {:error, :rate_limited} ->
        assign(socket, :pairing_error, "Too many requests. Please wait a minute and try again.")

      {:error, :create_claim_failed} ->
        assign(socket, :pairing_error, "Relay service returned an error. Please try again.")

      {:error, reason} ->
        Logger.error("Failed to generate pairing code: #{inspect(reason)}")

        assign(
          socket,
          :pairing_error,
          "Could not connect to the relay service. Check your connection and try again."
        )
    end
  end

  defp handle_countdown_tick(socket) do
    case socket.assigns.claim_expires_at do
      nil ->
        socket

      expires_at ->
        remaining = DateTime.diff(expires_at, DateTime.utc_now())

        if remaining > 0 do
          send(self(), :countdown_tick)
          assign(socket, :countdown_seconds, remaining)
        else
          socket
          |> assign(:claim_code, nil)
          |> assign(:claim_expires_at, nil)
          |> assign(:countdown_seconds, 0)
          |> put_flash(:info, "Pairing code expired")
        end
    end
  end

  defp load_p2p_status(socket) do
    {:ok, status} = RemoteAccess.p2p_status()
    assign(socket, :p2p_status, status)
  end

  defp normalize_code(nil), do: nil

  defp normalize_code(code) when is_binary(code) do
    code |> String.replace(~r/[\s-]/, "") |> String.upcase()
  end

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
