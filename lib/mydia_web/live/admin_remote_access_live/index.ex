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
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Remote Access")
     |> assign(:active_tab, :remote_access)
     |> assign(:show_add_url_modal, false)
     |> assign(:new_url, "")
     |> assign(:show_advanced, false)
     |> load_config()
     |> load_p2p_status()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_p2p, socket) do
    schedule_refresh()
    {:noreply, refresh_status(socket)}
  end

  ## Event Handlers

  @impl true
  def handle_event("toggle_remote_access", params, socket) do
    enabled_str = Map.get(params, "enabled", "false")
    enabled = enabled_str == "true"
    config = socket.assigns.ra_config

    with {:ok, socket} <- maybe_initialize_config(socket, config, enabled),
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

  def handle_event("copy_peer_id", _params, socket) do
    {:noreply, put_flash(socket, :info, "Node ID copied to clipboard")}
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

  ## Private Helpers

  defp maybe_initialize_config(socket, nil, true) do
    case RemoteAccess.initialize_config() do
      {:ok, new_config} ->
        {:ok, assign(socket, :ra_config, new_config)}

      {:error, changeset} ->
        {:error, :init_failed, changeset}
    end
  end

  defp maybe_initialize_config(socket, _config, _enabled), do: {:ok, socket}

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

  defp refresh_status(socket) do
    load_p2p_status(socket)
  end

  defp load_config(socket) do
    config = RemoteAccess.get_config()
    assign(socket, :ra_config, config)
  end

  defp load_p2p_status(socket) do
    {:ok, p2p_status} = RemoteAccess.p2p_status()
    assign(socket, :p2p_status, p2p_status)
  end
end
