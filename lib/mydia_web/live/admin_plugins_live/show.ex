defmodule MydiaWeb.AdminPluginsLive.Show do
  @moduledoc """
  Plugin detail page: operator settings and instance-scoped service endpoints.
  """
  use MydiaWeb, :live_view

  alias Mydia.Plugins.Connect
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Endpoint
  alias Mydia.Plugins.Kv
  alias Mydia.Repo
  alias Mydia.Settings

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Plugin not found.")
         |> push_navigate(to: ~p"/admin/config/plugins")}

      plugin ->
        descriptor = instance_connection_descriptor(plugin)

        {:ok,
         socket
         |> assign(:page_title, "Configuration - #{plugin.name}")
         |> assign(:active_tab, :plugins)
         |> assign(:plugin, plugin)
         |> assign(:connection_descriptor, descriptor)
         |> assign(:connection_form, nil)
         |> assign(:connect_session, nil)
         |> load_connections()}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("connection:add", _params, socket) do
    {:noreply, open_connection_form(socket, :add, nil)}
  end

  @impl true
  def handle_event("connection:edit", %{"label" => label}, socket) do
    conn = Connections.get_by_label(socket.assigns.plugin.slug, nil, label)
    {:noreply, open_connection_form(socket, :edit, conn)}
  end

  @impl true
  def handle_event("connection:cancel", _params, socket) do
    {:noreply, assign(socket, :connection_form, nil)}
  end

  @impl true
  def handle_event("connection:save", %{"connection" => params}, socket) do
    slug = socket.assigns.plugin.slug
    descriptor = socket.assigns.connection_descriptor
    form_state = socket.assigns.connection_form

    existing =
      case form_state.mode do
        :edit -> Connections.get_by_label(slug, nil, form_state.label)
        :add -> nil
      end

    attrs = build_connection_attrs(params, descriptor, existing)

    socket =
      case Connections.upsert(slug, attrs) do
        {:ok, _} ->
          socket
          |> put_flash(:info, "Connection saved.")
          |> assign(:connection_form, nil)
          |> load_connections()

        {:error, %Ecto.Changeset{}} ->
          put_flash(socket, :error, "Could not save connection. Check the fields and try again.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not save connection: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("connection:remove", %{"label" => label}, socket) do
    slug = socket.assigns.plugin.slug

    socket =
      case Connections.get_by_label(slug, nil, label) do
        nil ->
          socket

        conn ->
          Kv.delete_connection_prefix(conn.plugin_slug, conn.id)
          Repo.delete!(conn)

          socket
          |> put_flash(:info, "Connection removed.")
          |> load_connections()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("connection:test", %{"label" => label}, socket) do
    slug = socket.assigns.plugin.slug

    socket =
      case Connections.get_by_label(slug, nil, label) do
        nil ->
          put_flash(socket, :error, "Connection not found.")

        conn ->
          case Endpoint.resolve(conn) do
            {:ok, url} ->
              {:ok, _} = Connections.set_resolved_base_url(conn, url)

              socket
              |> put_flash(:info, "Reachable at #{url}")
              |> load_connections()

            {:error, error} ->
              message =
                if function_exported?(error.__struct__, :message, 1),
                  do: error.__struct__.message(error),
                  else: inspect(error)

              put_flash(socket, :error, "Connection test failed: #{message}")
          end
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("connect:start", _params, socket) do
    slug = socket.assigns.plugin.slug

    socket =
      case Connect.start(slug) do
        {:ok, session} ->
          socket
          |> assign(:connect_session, connect_session_state(session))
          |> maybe_flash_connect_done(session)

        {:error, error} ->
          put_flash(socket, :error, connect_error_message(error))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("connect:poll", _params, socket) do
    session = socket.assigns.connect_session

    socket =
      case Connect.poll(session.id) do
        {:ok, updated} ->
          socket
          |> assign(:connect_session, connect_session_state(updated))
          |> maybe_flash_connect_done(updated)
          |> load_connections()

        {:error, error} ->
          put_flash(socket, :error, connect_error_message(error))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("connect:submit", params, socket) do
    session = socket.assigns.connect_session
    input = Map.get(params, "connect", params)

    socket =
      case Connect.submit(session.id, input) do
        {:ok, updated} ->
          socket
          |> assign(:connect_session, connect_session_state(updated))
          |> maybe_flash_connect_done(updated)
          |> load_connections()

        {:error, error} ->
          put_flash(socket, :error, connect_error_message(error))
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("connect:cancel", _params, socket) do
    if session = socket.assigns.connect_session do
      Connect.cancel(session.id)
    end

    {:noreply, assign(socket, :connect_session, nil)}
  end

  defp load_connections(socket) do
    slug = socket.assigns.plugin.slug
    connections = Connections.list_instance_for_plugin(slug)
    assign(socket, :connections, connections)
  end

  defp instance_connection_descriptor(%{manifest: manifest}) when is_map(manifest) do
    case Map.get(manifest, "connection") do
      %{"type" => "service_endpoint", "scope" => "instance"} = descriptor ->
        descriptor

      _ ->
        nil
    end
  end

  defp instance_connection_descriptor(_), do: nil

  defp open_connection_form(socket, mode, conn) do
    descriptor = socket.assigns.connection_descriptor
    fields = Map.get(descriptor, "fields", [])

    form_data =
      Enum.reduce(fields, %{"label" => (conn && conn.label) || ""}, fn field, acc ->
        key = field["key"]

        value =
          if field["secret"] do
            ""
          else
            field_value_for_form(conn, key)
          end

        Map.put(acc, key, value)
      end)

    assign(socket, :connection_form, %{
      mode: mode,
      label: conn && conn.label,
      form: to_form(form_data, as: :connection)
    })
  end

  defp field_value_for_form(nil, _key), do: ""

  defp field_value_for_form(conn, "url") do
    case conn.base_urls do
      [url | _] -> url
      _ -> ""
    end
  end

  defp field_value_for_form(_conn, _key), do: ""

  defp build_connection_attrs(params, descriptor, existing) do
    fields = Map.get(descriptor, "fields", [])
    auth = Map.get(descriptor, "auth", %{})

    secret_key =
      Enum.find_value(fields, fn field ->
        if field["secret"], do: field["key"]
      end)

    url_key =
      Enum.find_value(fields, fn field ->
        if field["key"] == "url", do: field["key"]
      end)

    token = if secret_key, do: Map.get(params, secret_key), else: nil

    access_token =
      cond do
        token not in [nil, ""] -> token
        existing -> existing.access_token
        true -> ""
      end

    base_urls =
      case url_key && Map.get(params, url_key) do
        url when url in [nil, ""] ->
          if existing, do: existing.base_urls, else: []

        url ->
          [url]
      end

    %{
      scope: "instance",
      label: Map.get(params, "label", ""),
      base_urls: base_urls,
      access_token: access_token,
      auth_kind: Map.get(auth, "kind", "bearer"),
      auth_key: Map.get(auth, "key")
    }
  end

  defp connect_session_state(%Connect.Session{} = session) do
    form_data =
      Enum.reduce(session.fields, %{}, fn field, acc ->
        Map.put(acc, field["key"], "")
      end)

    form_data =
      if session.choices != [] do
        Map.put(form_data, "choice", "")
      else
        form_data
      end

    %{
      id: session.id,
      status: session.status,
      message: session.message,
      code: session.code,
      verification_url: session.verification_url,
      fields: session.fields,
      choices: session.choices,
      form: to_form(form_data, as: :connect)
    }
  end

  defp maybe_flash_connect_done(socket, %Connect.Session{status: :done, message: message}) do
    msg = message || "Connected."
    put_flash(socket, :info, msg)
  end

  defp maybe_flash_connect_done(socket, _session), do: socket

  defp connect_error_message(%{__struct__: _} = error) do
    if function_exported?(error.__struct__, :message, 1) do
      error.__struct__.message(error)
    else
      inspect(error)
    end
  end

  defp connect_error_message(other), do: inspect(other)
end
