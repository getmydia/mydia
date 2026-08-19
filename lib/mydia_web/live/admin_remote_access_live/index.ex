defmodule MydiaWeb.AdminRemoteAccessLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.RemoteAccess

  require Logger

  # Which paired devices are online is derived from `last_seen_at` and from the
  # live p2p peer count, and both move while this page sits open. Without a
  # timer the page shows whatever was true at mount, so a device connecting a
  # moment later never appears until someone clicks refresh.
  @refresh_interval_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "remote_access:claims")
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Remote Access")
     |> assign(:active_tab, :remote_access)
     |> assign(:claim_code, nil)
     |> assign(:claim_expires_at, nil)
     |> assign(:countdown_seconds, 0)
     |> assign(:claim_code_rendezvous_status, nil)
     |> assign(:pairing_error, nil)
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)
     |> assign(:show_pairing_modal, false)
     |> assign(:show_add_url_modal, false)
     |> assign(:new_url, "")
     |> assign(:show_advanced, false)
     |> assign(:show_all_devices, false)
     |> assign(:show_clear_inactive_modal, false)
     |> load_config()
     |> load_devices()
     |> load_p2p_status()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## Timer handling (direct, no relay)

  @impl true
  def handle_info(:countdown_tick, socket) do
    Process.send_after(self(), :do_countdown_tick, 1000)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_countdown_tick, socket) do
    {:noreply, handle_countdown_tick(socket)}
  end

  @impl true
  def handle_info(:refresh_p2p, socket) do
    schedule_refresh()
    {:noreply, refresh_status(socket)}
  end

  @impl true
  def handle_info({:claim_consumed, %{code: code, user_id: user_id}}, socket) do
    socket =
      if socket.assigns.current_scope && socket.assigns.current_scope.user.id == user_id do
        current_code = socket.assigns.claim_code

        if current_code && normalize_code(current_code) == normalize_code(code) do
          socket
          |> assign(:claim_code, nil)
          |> assign(:claim_expires_at, nil)
          |> assign(:countdown_seconds, 0)
          |> assign(:show_pairing_modal, false)
          |> load_devices()
          |> put_flash(:info, "Device paired successfully!")
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  ## Event Handlers

  @impl true
  def handle_event("toggle_remote_access", params, socket) do
    enabled_str = Map.get(params, "enabled", "false")
    enabled = enabled_str == "true"
    config = socket.assigns.ra_config

    with {:ok, socket} <- maybe_initialize_keypair(socket, config, enabled),
         {:ok, updated_config} <- RemoteAccess.toggle_remote_access(enabled),
         :ok <- maybe_start_or_stop_p2p(enabled) do
      {:noreply,
       socket
       |> assign(:ra_config, updated_config)
       |> load_p2p_status()
       |> put_flash(:info, "Remote access #{if enabled, do: "enabled", else: "disabled"}")}
    else
      {:error, :init_failed, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to initialize remote access: #{format_errors(changeset)}")}

      {:error, :not_configured} ->
        {:noreply,
         socket
         |> put_flash(:error, "Remote access not configured. Please try again.")}

      {:error, :remote_access_not_configured} ->
        {:noreply,
         socket
         |> load_p2p_status()
         |> put_flash(:error, "Failed to start P2P: remote access not fully configured")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update remote access setting")}
    end
  end

  def handle_event("generate_claim_code", _params, socket) do
    Logger.debug("Generate claim code button clicked")
    {:noreply, do_generate_claim_code(socket)}
  end

  def handle_event("copy_claim_code", _params, socket) do
    {:noreply, put_flash(socket, :info, "Code copied to clipboard")}
  end

  def handle_event("copy_peer_id", _params, socket) do
    {:noreply, put_flash(socket, :info, "Node ID copied to clipboard")}
  end

  def handle_event("open_revoke_modal", %{"id" => id}, socket) do
    device = RemoteAccess.get_device!(id)

    {:noreply,
     socket
     |> assign(:show_revoke_modal, true)
     |> assign(:selected_device, device)}
  end

  def handle_event("close_revoke_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_revoke_modal, false)
     |> assign(:selected_device, nil)}
  end

  def handle_event("submit_revoke", _params, socket) do
    device = socket.assigns.selected_device

    case RemoteAccess.revoke_device(device) do
      {:ok, _revoked_device} ->
        {:noreply,
         socket
         |> assign(:show_revoke_modal, false)
         |> assign(:selected_device, nil)
         |> put_flash(:info, "Device revoked successfully.")
         |> load_devices()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to revoke device")}
    end
  end

  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    device = RemoteAccess.get_device!(id)

    {:noreply,
     socket
     |> assign(:show_delete_modal, true)
     |> assign(:device_to_delete, device)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:device_to_delete, nil)}
  end

  def handle_event("submit_delete", _params, socket) do
    device = socket.assigns.device_to_delete

    case RemoteAccess.delete_device(device) do
      {:ok, _deleted_device} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:device_to_delete, nil)
         |> put_flash(:info, "Device deleted successfully.")
         |> load_devices()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete device")}
    end
  end

  def handle_event("open_clear_inactive_modal", _params, socket) do
    {:noreply, assign(socket, :show_clear_inactive_modal, true)}
  end

  def handle_event("close_clear_inactive_modal", _params, socket) do
    {:noreply, assign(socket, :show_clear_inactive_modal, false)}
  end

  def handle_event("submit_clear_inactive", _params, socket) do
    devices = socket.assigns.devices

    # Find inactive devices (not recently active or revoked)
    inactive_devices =
      Enum.reject(devices, fn d ->
        recent_activity?(d.last_seen_at) && is_nil(d.revoked_at)
      end)

    # Delete all inactive devices
    deleted_count =
      Enum.reduce(inactive_devices, 0, fn device, count ->
        case RemoteAccess.delete_device(device) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    {:noreply,
     socket
     |> assign(:show_clear_inactive_modal, false)
     |> put_flash(
       :info,
       "Removed #{deleted_count} inactive device#{if deleted_count == 1, do: "", else: "s"}."
     )
     |> load_devices()}
  end

  def handle_event("open_pairing_modal", _params, socket) do
    # Open modal and immediately generate a code if we don't have one
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

  def handle_event("open_add_url_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_url_modal, true)
     |> assign(:new_url, "")}
  end

  def handle_event("close_add_url_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_url_modal, false)
     |> assign(:new_url, "")}
  end

  def handle_event("update_new_url", %{"url" => value}, socket) do
    {:noreply, assign(socket, :new_url, value)}
  end

  def handle_event("update_new_url", %{"direct_url" => %{"url" => value}}, socket) do
    {:noreply, assign(socket, :new_url, value)}
  end

  def handle_event("add_direct_url", _params, socket) do
    config = socket.assigns.ra_config
    new_url = String.trim(socket.assigns.new_url)

    if new_url != "" do
      current_urls = config.direct_urls || []
      updated_urls = Enum.uniq(current_urls ++ [new_url])

      case RemoteAccess.upsert_config(%{direct_urls: updated_urls}) do
        {:ok, _config} ->
          {:noreply,
           socket
           |> assign(:show_add_url_modal, false)
           |> assign(:new_url, "")
           |> load_config()
           |> put_flash(:info, "Direct URL added successfully")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to add direct URL: #{format_errors(changeset)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_direct_url", %{"url" => url}, socket) do
    config = socket.assigns.ra_config
    current_urls = config.direct_urls || []
    updated_urls = Enum.reject(current_urls, &(&1 == url))

    case RemoteAccess.upsert_config(%{direct_urls: updated_urls}) do
      {:ok, _config} ->
        {:noreply,
         socket
         |> load_config()
         |> put_flash(:info, "Direct URL removed successfully")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to remove direct URL: #{format_errors(changeset)}")}
    end
  end

  def handle_event("refresh_p2p", _params, socket) do
    {:noreply,
     socket
     |> refresh_status()
     |> put_flash(:info, "Status refreshed")}
  end

  def handle_event("toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :show_advanced, !socket.assigns.show_advanced)}
  end

  def handle_event("toggle_show_all_devices", _params, socket) do
    {:noreply, assign(socket, :show_all_devices, !socket.assigns.show_all_devices)}
  end

  ## Private Helpers

  defp handle_countdown_tick(socket) do
    claim_expires_at = socket.assigns.claim_expires_at

    if claim_expires_at do
      now = DateTime.utc_now()
      seconds_remaining = DateTime.diff(claim_expires_at, now, :second)

      if seconds_remaining > 0 do
        # Schedule the next tick directly
        send(self(), :countdown_tick)
        assign(socket, :countdown_seconds, seconds_remaining)
      else
        socket
        |> assign(:claim_code, nil)
        |> assign(:claim_expires_at, nil)
        |> assign(:countdown_seconds, 0)
        |> put_flash(:info, "Pairing code expired")
      end
    else
      socket
    end
  end

  defp do_generate_claim_code(socket) do
    user_id = socket.assigns.current_user.id
    p2p_status = socket.assigns.p2p_status

    Logger.debug("Generating pairing code for user #{user_id}, p2p_status=#{inspect(p2p_status)}")

    case RemoteAccess.generate_claim_code(user_id) do
      {:ok, claim} ->
        Logger.info("Pairing code generated successfully: #{claim.code}")
        expires_at = claim.expires_at
        now = DateTime.utc_now()
        seconds = DateTime.diff(expires_at, now, :second)

        # Schedule the first countdown tick directly
        send(self(), :countdown_tick)

        socket
        |> assign(:pairing_error, nil)
        |> assign(:claim_code, claim.code)
        |> assign(:claim_code_rendezvous_status, :registered)
        |> assign(:claim_expires_at, expires_at)
        |> assign(:countdown_seconds, max(0, seconds))

      {:error, :p2p_not_running} ->
        Logger.warning("Failed to generate pairing code: P2P service not running")
        assign(socket, :pairing_error, "P2P service is not running. Please try again.")

      {:error, :p2p_not_ready} ->
        Logger.warning("Failed to generate pairing code: P2P not ready yet")

        assign(
          socket,
          :pairing_error,
          "P2P service is still starting up. Please try again in a moment."
        )

      {:error, :rate_limited} ->
        Logger.warning("Failed to generate pairing code: rate limited by relay")
        assign(socket, :pairing_error, "Too many requests. Please wait a minute and try again.")

      {:error, :create_claim_failed} ->
        Logger.error("Failed to generate pairing code: relay returned an error")
        assign(socket, :pairing_error, "Relay service returned an error. Please try again.")

      {:error, reason} ->
        Logger.error("Failed to generate pairing code: #{inspect(reason)}")

        assign(
          socket,
          :pairing_error,
          "Could not connect to relay service. Please check your connection and try again."
        )
    end
  end

  defp maybe_initialize_keypair(socket, nil, true) do
    case RemoteAccess.initialize_keypair() do
      {:ok, new_config} ->
        {:ok, assign(socket, :ra_config, new_config)}

      {:error, changeset} ->
        {:error, :init_failed, changeset}
    end
  end

  defp maybe_initialize_keypair(socket, _config, _enabled), do: {:ok, socket}

  # P2P is started automatically by the application supervision tree
  # These are effectively no-ops now but kept for API compatibility
  defp maybe_start_or_stop_p2p(true), do: RemoteAccess.start_relay()
  defp maybe_start_or_stop_p2p(false), do: RemoteAccess.stop_relay()

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp format_errors(_), do: "unknown error"

  defp schedule_refresh do
    Process.send_after(self(), :refresh_p2p, @refresh_interval_ms)
  end

  # Device liveness lives in `last_seen_at`, so the device list has to be
  # re-read alongside the p2p status for online badges to move.
  defp refresh_status(socket) do
    socket
    |> load_p2p_status()
    |> load_devices()
  end

  defp load_config(socket) do
    config = RemoteAccess.get_config()
    assign(socket, :ra_config, config)
  end

  defp load_devices(socket) do
    user_id = socket.assigns.current_user.id
    devices = RemoteAccess.list_devices(user_id)
    assign(socket, :devices, devices)
  end

  defp load_p2p_status(socket) do
    {:ok, p2p_status} = RemoteAccess.p2p_status()
    assign(socket, :p2p_status, p2p_status)
  end

  # Normalize claim code by removing whitespace and dashes, converting to uppercase
  defp normalize_code(code) when is_binary(code) do
    code
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
  end

  defp normalize_code(nil), do: nil

  # Consider a device "active" (online now) if seen within the last 10 minutes.
  @active_threshold_seconds 600

  defp recent_activity?(nil), do: false

  defp recent_activity?(last_seen) do
    threshold = DateTime.utc_now() |> DateTime.add(-@active_threshold_seconds, :second)
    DateTime.compare(last_seen, threshold) == :gt
  end
end
