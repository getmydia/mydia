defmodule MydiaWeb.IntegrationsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Integrations
  alias Mydia.Integrations.Trakt.Client, as: TraktClient
  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.DeviceFlow

  require Logger

  @trakt_not_configured_message "Trakt is unavailable because the metadata relay this server " <>
                                  "uses has no Trakt credentials configured. If you run your own " <>
                                  "relay, set TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET on it."

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    trakt_integration = Integrations.get_user_integration(user.id, "trakt")

    socket =
      socket
      # Trakt integration
      |> assign(:trakt_integration, trakt_integration)
      |> assign(:trakt_device_code, nil)
      |> assign(:trakt_user_code, nil)
      |> assign(:trakt_verification_url, nil)
      |> assign(:trakt_polling, false)
      |> assign(:trakt_poll_interval, nil)
      |> assign(:trakt_error, nil)
      # Generic plugin connections (U8)
      |> assign(:plugin_connections, load_plugin_connections(user.id))
      |> assign(:plugin_connect, nil)

    {:ok, socket}
  end

  defp load_plugin_connections(user_id) do
    Enum.map(Plugins.list_connectable(), fn pc ->
      Map.put(pc, :connection, Connections.get(pc.slug, user_id))
    end)
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "Integrations")}
  end

  ## Trakt Events

  @impl true
  def handle_event("trakt_connect", _params, socket) do
    case TraktClient.generate_device_code() do
      {:ok, data} ->
        interval = (data["interval"] || 5) * 1000
        Process.send_after(self(), :trakt_poll, interval)

        {:noreply,
         socket
         |> assign(:trakt_device_code, data["device_code"])
         |> assign(:trakt_user_code, data["user_code"])
         |> assign(:trakt_verification_url, data["verification_url"])
         |> assign(:trakt_polling, true)
         |> assign(:trakt_poll_interval, interval)
         |> assign(:trakt_error, nil)}

      {:error, reason} ->
        Logger.error("Failed to generate Trakt device code: #{inspect(reason)}")

        message =
          trakt_error_message(reason, "Failed to start Trakt authorization. Please try again.")

        {:noreply, assign(socket, :trakt_error, message)}
    end
  end

  @impl true
  def handle_event("trakt_cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(:trakt_device_code, nil)
     |> assign(:trakt_user_code, nil)
     |> assign(:trakt_verification_url, nil)
     |> assign(:trakt_polling, false)
     |> assign(:trakt_poll_interval, nil)
     |> assign(:trakt_error, nil)}
  end

  @impl true
  def handle_event("trakt_disconnect", _params, socket) do
    user = socket.assigns.current_user

    case Integrations.get_user_integration(user.id, "trakt") do
      nil ->
        {:noreply, assign(socket, :trakt_integration, nil)}

      integration ->
        # Best-effort revoke
        TraktClient.revoke_token(integration.access_token)
        Integrations.delete_user_integration(integration)

        {:noreply,
         socket
         |> assign(:trakt_integration, nil)
         |> put_flash(:info, "Trakt.tv disconnected")}
    end
  end

  @impl true
  def handle_event("plugin_connect", %{"slug" => slug}, socket) do
    case find_connectable(socket, slug) do
      nil ->
        {:noreply, socket}

      pc ->
        opts = [allowed_hosts: pc.allowed_hosts, slug: slug]

        case DeviceFlow.request_code(pc.descriptor, pc.client_id, opts) do
          {:ok, code} ->
            Process.send_after(self(), {:plugin_poll, slug}, code.interval_ms)

            connect =
              Map.merge(pc, %{
                user_code: code.user_code,
                verification_url: code.verification_url,
                device_code: code.device_code,
                interval_ms: code.interval_ms,
                expires_at: System.system_time(:second) + code.expires_in_s,
                error: nil
              })

            {:noreply, assign(socket, :plugin_connect, connect)}

          {:error, reason} ->
            Logger.warning("plugin #{slug} connect failed: #{inspect(reason)}")

            {:noreply,
             assign(socket, :plugin_connect, %{
               slug: slug,
               error: "Could not start the connection. Please try again."
             })}
        end
    end
  end

  @impl true
  def handle_event("plugin_cancel", _params, socket) do
    {:noreply, assign(socket, :plugin_connect, nil)}
  end

  @impl true
  def handle_event("plugin_disconnect", %{"slug" => slug}, socket) do
    user = socket.assigns.current_user
    Connections.disconnect(slug, user.id)

    {:noreply,
     socket
     |> assign(:plugin_connections, load_plugin_connections(user.id))
     |> assign(:plugin_connect, nil)
     |> put_flash(:info, "Disconnected.")}
  end

  @impl true
  def handle_info(:trakt_poll, socket) do
    if socket.assigns.trakt_polling do
      device_code = socket.assigns.trakt_device_code
      interval = socket.assigns.trakt_poll_interval

      case TraktClient.poll_device_token(device_code) do
        {:ok, token_data} ->
          user = socket.assigns.current_user

          attrs = %{
            provider: "trakt",
            access_token: token_data["access_token"],
            refresh_token: token_data["refresh_token"],
            token_expires_at: compute_trakt_expiry(token_data["expires_in"]),
            scopes: Map.get(token_data, "scope")
          }

          case Integrations.create_user_integration(user.id, attrs) do
            {:ok, integration} ->
              {:noreply,
               socket
               |> assign(:trakt_integration, integration)
               |> assign(:trakt_device_code, nil)
               |> assign(:trakt_user_code, nil)
               |> assign(:trakt_verification_url, nil)
               |> assign(:trakt_polling, false)
               |> assign(:trakt_poll_interval, nil)
               |> assign(:trakt_error, nil)
               |> put_flash(:info, "Trakt.tv connected successfully!")}

            {:error, reason} ->
              Logger.error("Failed to save Trakt integration: #{inspect(reason)}")

              {:noreply,
               socket
               |> assign(:trakt_polling, false)
               |> assign(:trakt_error, "Failed to save Trakt connection.")}
          end

        {:error, {:http_error, 400, _}} ->
          # Pending — schedule next poll
          Process.send_after(self(), :trakt_poll, interval)
          {:noreply, socket}

        {:error, {:http_error, 410, _}} ->
          # Expired
          {:noreply,
           socket
           |> assign(:trakt_polling, false)
           |> assign(:trakt_device_code, nil)
           |> assign(:trakt_user_code, nil)
           |> assign(:trakt_verification_url, nil)
           |> assign(:trakt_error, "Authorization code expired. Please try again.")}

        {:error, {:http_error, 418, _}} ->
          # Denied
          {:noreply,
           socket
           |> assign(:trakt_polling, false)
           |> assign(:trakt_device_code, nil)
           |> assign(:trakt_user_code, nil)
           |> assign(:trakt_verification_url, nil)
           |> assign(:trakt_error, "Authorization was denied.")}

        {:error, {:http_error, 429, _}} ->
          # Slow down — increase interval
          new_interval = interval + 1000
          Process.send_after(self(), :trakt_poll, new_interval)
          {:noreply, assign(socket, :trakt_poll_interval, new_interval)}

        {:error, reason} ->
          Logger.error("Trakt device poll error: #{inspect(reason)}")

          {:noreply,
           socket
           |> assign(:trakt_polling, false)
           |> assign(
             :trakt_error,
             trakt_error_message(reason, "An error occurred. Please try again.")
           )}
      end
    else
      {:noreply, socket}
    end
  end

  ## Plugin Connections (U8)

  @impl true
  def handle_info({:plugin_poll, slug}, socket) do
    connect = socket.assigns.plugin_connect

    if connect && connect.slug == slug && Map.get(connect, :user_code) do
      poll_plugin(socket, connect, slug)
    else
      {:noreply, socket}
    end
  end

  defp poll_plugin(socket, connect, slug) do
    if System.system_time(:second) >= connect.expires_at do
      {:noreply,
       assign(socket, :plugin_connect, connect_error(slug, "The code expired. Please try again."))}
    else
      opts = [allowed_hosts: connect.allowed_hosts, slug: slug]

      handle_poll(
        socket,
        connect,
        slug,
        DeviceFlow.poll(
          connect.descriptor,
          %{user_code: connect.user_code, device_code: Map.get(connect, :device_code)},
          connect.client_id,
          opts
        )
      )
    end
  end

  defp handle_poll(socket, connect, slug, {:ok, token}) do
    user = socket.assigns.current_user

    attrs = %{
      access_token: token.access_token,
      external_user_id: Map.get(token, :external_user_id),
      status: "connected"
    }

    case Connections.connect(slug, user.id, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:plugin_connect, nil)
         |> assign(:plugin_connections, load_plugin_connections(user.id))
         |> put_flash(:info, "#{connect.name} connected.")}

      {:error, _} ->
        {:noreply,
         assign(socket, :plugin_connect, connect_error(slug, "Could not save the connection."))}
    end
  end

  defp handle_poll(socket, connect, slug, :pending) do
    Process.send_after(self(), {:plugin_poll, slug}, connect.interval_ms)
    {:noreply, socket}
  end

  defp handle_poll(socket, connect, slug, :slow_down) do
    # Honor the provider's back-pressure: double the interval, capped at 30s.
    new_interval = min(connect.interval_ms * 2, 30_000)
    Process.send_after(self(), {:plugin_poll, slug}, new_interval)
    {:noreply, assign(socket, :plugin_connect, %{connect | interval_ms: new_interval})}
  end

  defp handle_poll(socket, _connect, slug, :expired) do
    {:noreply,
     assign(socket, :plugin_connect, connect_error(slug, "The code expired. Please try again."))}
  end

  defp handle_poll(socket, _connect, slug, :denied) do
    {:noreply, assign(socket, :plugin_connect, connect_error(slug, "Authorization was denied."))}
  end

  defp handle_poll(socket, connect, slug, {:error, _reason}) do
    # A transient gate/network error — keep polling until expiry.
    Process.send_after(self(), {:plugin_poll, slug}, connect.interval_ms)
    {:noreply, socket}
  end

  defp connect_error(slug, message), do: %{slug: slug, error: message}

  defp find_connectable(socket, slug) do
    Enum.find(socket.assigns.plugin_connections, &(&1.slug == slug))
  end

  ## Private Helpers

  # The relay answers 503 with this code when it carries no Trakt credentials.
  # Retrying never clears it, so say what actually needs to happen.
  defp trakt_error_message({:http_error, 503, %{"error" => "trakt_not_configured"}}, _fallback),
    do: @trakt_not_configured_message

  defp trakt_error_message(_reason, fallback), do: fallback

  defp compute_trakt_expiry(nil), do: nil

  defp compute_trakt_expiry(expires_in) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.truncate(:second)
  end
end
