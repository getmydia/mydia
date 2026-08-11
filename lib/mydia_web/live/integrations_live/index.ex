defmodule MydiaWeb.IntegrationsLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.DeviceFlow

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
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
end
