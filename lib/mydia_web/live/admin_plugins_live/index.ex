defmodule MydiaWeb.AdminPluginsLive.Index do
  @moduledoc """
  Admin plugin store and capability-approval UI (U9).

  Mirrors the service-config row+modal pattern (download clients / indexers).
  The emphasized surface is the **capability-approval modal**: for a plugin whose
  grant is empty, activation is blocked until the admin explicitly accepts the
  declared capabilities, which are rendered in host-owned plain language
  (`MydiaWeb.AdminPluginsLive.Components`), with network egress made legible.
  Bundled rows arrive already granted and enabled, so the modal is not part of
  their path. Env/index-sourced rows render read-only with a source badge
  (provenance).
  """
  use MydiaWeb, :live_view

  require Logger

  alias Mydia.Events
  alias Mydia.Plugins
  alias Mydia.Plugins.DeclaredSettings
  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Index.BrowseResult
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Log
  alias Mydia.Plugins.Logs
  alias Mydia.Plugins.Shelves
  alias Mydia.Settings

  # Max log rows loaded into the detail timeline on open / filter.
  @log_limit 200

  @ceiling_roles ~w(admin user guest readonly)

  @impl true
  def mount(_params, _session, socket) do
    # Reconcile bundled plugins on view. `ensure_bundled/0` otherwise runs only at
    # boot, so a node that started before a bundled manifest shipped never seeds it
    # (the common dev case: the BEAM stays up across plugin additions). Connected-
    # only and gated, so the test suite's empty-state list stays clean.
    if connected?(socket), do: Plugins.maybe_ensure_bundled()

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Plugins")
     |> assign(:browse, nil)
     |> assign(:browsing?, false)
     |> assign(:approval, nil)
     |> assign(:detail, nil)
     |> assign(:logs, nil)
     |> assign(:settings, nil)
     |> assign(:log_topic, nil)
     |> assign(:net_subscribed?, false)
     |> stream(:plugin_logs, [])
     |> stream(:plugin_net, [])
     |> load_installed()
     |> load_updates()}
  end

  ## Store browsing (R13)

  @impl true
  def handle_event("browse_store", _params, %{assigns: %{browsing?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("browse_store", _params, socket) do
    # Computed outside the closure so the task does not copy the socket.
    slugs = Enum.map(socket.assigns.installed, & &1.slug)

    {:noreply,
     socket
     |> assign(browsing?: true, browse: nil)
     |> start_async(:browse, fn -> Index.browse(slugs) end)}
  end

  ## Capability approval (KTD6, AE1)

  def handle_event("review_install", %{"slug" => slug}, socket) do
    case Enum.find(catalog_of(socket.assigns.browse), &(&1.slug == slug)) do
      nil -> {:noreply, socket}
      entry -> {:noreply, assign(socket, :approval, approval_from_entry(entry))}
    end
  end

  def handle_event("review_approve", %{"slug" => slug}, socket) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil -> {:noreply, socket}
      config -> {:noreply, assign(socket, :approval, approval_from_config(config))}
    end
  end

  def handle_event("decline_approval", _params, socket) do
    {:noreply, assign(socket, :approval, nil)}
  end

  def handle_event("confirm_approval", _params, %{assigns: %{approval: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_approval", _params, socket) do
    approval = socket.assigns.approval

    result =
      case approval.kind do
        :catalog -> Plugins.install(approval.entry)
        :installed -> Plugins.approve(approval.slug)
      end

    socket =
      case result do
        {:ok, _} ->
          socket
          |> put_flash(:info, approval_flash(approval))
          |> assign(:approval, nil)
          |> assign(:browse, nil)
          |> load_installed()

        {:error, error} ->
          put_flash(socket, :error, "Could not activate: #{error_message(error)}")
      end

    {:noreply, socket}
  end

  ## Lifecycle (R14)

  def handle_event("toggle_enabled", %{"slug" => slug}, socket) do
    config = Settings.get_plugin_config_by_slug(slug)
    enable? = !(config && config.enabled)
    apply_lifecycle(socket, fn -> Plugins.set_enabled(slug, enable?) end, "Updated #{slug}.")
  end

  def handle_event("revoke", %{"slug" => slug}, socket) do
    apply_lifecycle(socket, fn -> Plugins.revoke(slug) end, "Revoked #{slug}.")
  end

  def handle_event("remove", %{"slug" => slug}, socket) do
    apply_lifecycle(socket, fn -> Plugins.remove(slug) end, "Removed #{slug}.")
  end

  ## Settings modal (operator-editable config — U3)

  def handle_event("edit_settings", %{"slug" => slug}, socket) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil -> {:noreply, socket}
      config -> {:noreply, open_settings(socket, config)}
    end
  end

  def handle_event("close_settings", _params, socket) do
    {:noreply, assign(socket, :settings, nil)}
  end

  # Re-renders the open modal as the operator edits, so `visible_when` fields
  # show/hide live when the controlling value (e.g. `target`) changes. No save.
  def handle_event("settings_changed", params, socket) do
    case socket.assigns.settings do
      nil ->
        {:noreply, socket}

      settings ->
        values = Map.drop(params, ["slug", "_target"])

        {:noreply, assign(socket, :settings, %{settings | values: values, form: to_form(values)})}
    end
  end

  def handle_event("save_ceilings", %{"slug" => slug, "ceilings" => ceilings}, socket)
      when is_binary(slug) and is_map(ceilings) do
    with %{} = config <- Settings.get_plugin_config_by_slug(slug),
         true <- page_writes?(config),
         {:ok, _} <- Grants.put_ceilings(slug, ceilings) do
      settings =
        case socket.assigns.settings do
          %{slug: ^slug} = open -> %{open | ceilings_form: ceilings_form(config)}
          other -> other
        end

      {:noreply, socket |> assign(:settings, settings) |> put_flash(:info, "Permissions saved.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not save permissions.")}
    end
  end

  def handle_event("save_ceilings", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Could not save permissions.")}

  def handle_event("save_settings", %{"slug" => slug} = params, socket) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil ->
        {:noreply, socket}

      config ->
        schema = settings_schema_of(config)
        # Env-declared keys are read-only here: DeclaredSettings owns them.
        settings = schema |> build_settings(params) |> Map.drop(DeclaredSettings.keys(config))

        socket =
          with :ok <- Plugins.validate_url_settings(schema, settings),
               {:ok, _} <- Plugins.update_settings(slug, settings) do
            socket
            |> put_flash(:info, "#{config.name} settings saved.")
            |> assign(:settings, nil)
            |> load_installed()
          else
            {:error, message} when is_binary(message) ->
              # Keep the modal open so the operator can correct the value.
              put_flash(socket, :error, message)

            {:error, error} ->
              put_flash(socket, :error, error_message(error))
          end

        {:noreply, socket}
    end
  end

  ## Detail modal (granted caps + host grants)

  def handle_event("show_detail", %{"slug" => slug}, socket) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil -> {:noreply, socket}
      config -> {:noreply, assign(socket, :detail, detail_for(config))}
    end
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :detail, nil)}
  end

  ## Logs modal (U6/U7) — activity log + network activity + test

  def handle_event("show_logs", %{"slug" => slug}, socket) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil ->
        {:noreply, socket}

      config ->
        socket = subscribe_logs(socket, slug)
        logs = Logs.recent(slug, limit: @log_limit)

        {:noreply,
         socket
         |> assign(:logs, logs_for(config))
         |> stream(:plugin_logs, logs, reset: true)
         |> stream(:plugin_net, network_events(slug), reset: true)}
    end
  end

  def handle_event("close_logs", _params, socket) do
    {:noreply,
     socket
     |> unsubscribe_logs()
     |> assign(:logs, nil)
     |> stream(:plugin_logs, [], reset: true)
     |> stream(:plugin_net, [], reset: true)}
  end

  ## Debug logs (U6) — filter + live tail

  def handle_event("filter_logs", params, socket) do
    logs = socket.assigns.logs
    min_level = parse_level(params["level"])
    query = String.trim(params["query"] || "")
    rows = Logs.recent(logs.slug, limit: @log_limit, min_level: min_level, query: query)

    {:noreply,
     socket
     |> assign(:logs, %{logs | min_level: min_level, query: query})
     |> stream(:plugin_logs, rows, reset: true)}
  end

  ## Test trigger (U7)

  def handle_event("test_plugin", %{"slug" => slug, "event" => event_type}, socket) do
    case Plugins.test_invoke(slug, event_type) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Test #{event_type} dispatched to #{slug}.")}

      {:error, :no_instance} ->
        {:noreply, put_flash(socket, :error, "#{slug} has no enabled instance to test.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "#{slug} is not running — enable it first.")}
    end
  end

  ## Live tail (U6) — activity log + network activity

  @impl true
  def handle_async(:browse, {:ok, %BrowseResult{} = result}, socket) do
    {:noreply, assign(socket, browse: result, browsing?: false)}
  end

  def handle_async(:browse, {:exit, reason}, socket) do
    Logger.warning("plugin store lookup failed: #{inspect(reason)}")

    result = %BrowseResult{
      status: :empty,
      error: "store lookup failed",
      source_count: length(Index.sources())
    }

    {:noreply, assign(socket, browse: result, browsing?: false)}
  end

  @impl true
  def handle_info({:plugin_log, %Log{} = log}, socket) do
    logs = socket.assigns.logs

    if logs && log.slug == logs.slug && level_visible?(log.level, logs.min_level) &&
         query_visible?(log.message, logs.query) do
      {:noreply, stream_insert(socket, :plugin_logs, log, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_created, event}, socket) do
    logs = socket.assigns.logs

    if logs && network_event_for?(event, logs.slug) do
      {:noreply, stream_insert(socket, :plugin_net, event, at: 0)}
    else
      {:noreply, socket}
    end
  end

  ## Helpers

  defp approval_flash(%{ungranted: ungranted, name: name}) when ungranted != %{},
    do: "#{name} re-approved. Its newly requested capabilities are now granted."

  defp approval_flash(%{name: name}), do: "#{name} approved and activated."

  defp network_event_for?(%{type: "plugin.http_request"} = event, slug),
    do: event.actor_id == slug

  defp network_event_for?(_event, _slug), do: false

  # Subscribes to both the per-plugin activity-log topic and the global events
  # feed (filtered to this plugin's http_request audit rows) so the logs modal
  # live-tails activity and network requests together.
  defp subscribe_logs(socket, slug) do
    socket = unsubscribe_logs(socket)
    topic = Logs.topic(slug)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, topic)
      Events.subscribe()
    end

    socket
    |> assign(:log_topic, topic)
    |> assign(:net_subscribed?, true)
  end

  defp unsubscribe_logs(%{assigns: %{log_topic: nil, net_subscribed?: false}} = socket),
    do: socket

  defp unsubscribe_logs(socket) do
    if connected?(socket) do
      if socket.assigns.log_topic,
        do: Phoenix.PubSub.unsubscribe(Mydia.PubSub, socket.assigns.log_topic)

      if socket.assigns.net_subscribed?, do: Events.unsubscribe()
    end

    socket
    |> assign(:log_topic, nil)
    |> assign(:net_subscribed?, false)
  end

  defp parse_level(level) do
    case level do
      l when l in ["debug", "info", "warn", "error"] -> String.to_existing_atom(l)
      _ -> :debug
    end
  end

  defp level_visible?(level, min_level), do: Log.level_rank(level) >= Log.level_rank(min_level)

  defp query_visible?(_message, query) when query in [nil, ""], do: true

  defp query_visible?(message, query),
    do: String.contains?(String.downcase(message || ""), String.downcase(query))

  defp apply_lifecycle(socket, fun, success_msg) do
    socket =
      case fun.() do
        {:ok, _} ->
          socket
          |> put_flash(:info, success_msg)
          |> assign(:detail, nil)
          |> load_installed()

        {:error, error} ->
          put_flash(socket, :error, error_message(error))
      end

    {:noreply, socket}
  end

  defp open_settings(socket, config) do
    if Instances.multi_instance?(config),
      do: socket,
      else: assign(socket, :settings, settings_state(config))
  end

  # The schema whose host-granting fields widen the plugin-wide net:http grant.
  # A multi_instance plugin's endpoints are approved per instance instead.
  defp host_grant_schema_of(config) do
    if Instances.multi_instance?(config), do: [], else: settings_schema_of(config)
  end

  defp load_installed(socket) do
    rows = Settings.list_plugin_configs() |> Enum.map(&row/1)
    assign(socket, :installed, rows)
  end

  # Normalizes a config into a render row.
  defp row(config) do
    capabilities = capabilities_of(config)
    settings_schema = settings_schema_of(config)
    granted = config.granted_capabilities || %{}
    multi_instance = Map.get(config.manifest || %{}, "multi_instance", false) == true

    %{
      multi_instance: multi_instance,
      instances: if(multi_instance, do: Mydia.Plugins.Instances.list(config.slug), else: []),
      slug: config.slug,
      name: config.name,
      version: config.version,
      enabled: config.enabled,
      source: :index,
      capabilities: capabilities,
      granted: granted,
      # A revised manifest never widens a grant, so an approved plugin can end up
      # asking for more than it holds and failing Denied at just those call sites.
      ungranted: Plugins.ungranted_capabilities(config),
      needs_reapproval: Plugins.needs_reapproval?(config),
      shelf_failures: Shelves.failure_summary(config.slug),
      # Enabled/disabled is a runtime choice after approval; an empty grant means
      # capabilities are still pending approval.
      pending_approval: capabilities != %{} and granted == %{},
      # A multi_instance plugin is configured per instance on Media servers; a
      # plugin-level form would write settings no instance reads. The role
      # ceilings of a page plugin still live in this modal.
      has_settings: (settings_schema != [] and not multi_instance) or page_writes?(config),
      # Once approved, the granted net:http reflects the operator-configured host.
      network_hosts: Map.get(granted, "net:http", Map.get(capabilities, "net:http", []))
    }
  end

  defp capabilities_of(%{manifest: %{"capabilities" => caps}}) when is_map(caps), do: caps
  defp capabilities_of(%{granted_capabilities: caps}) when is_map(caps), do: caps
  defp capabilities_of(_), do: %{}

  defp settings_schema_of(%{manifest: %{"settings_schema" => schema}}) when is_list(schema),
    do: schema

  defp settings_schema_of(_), do: []

  # Builds the settings modal state. Secret values are not echoed back into the
  # form (write-only) — a blank secret on save preserves the stored one.
  defp settings_state(config) do
    schema = settings_schema_of(config)
    current = config.settings || %{}

    form_data =
      Enum.reduce(schema, %{}, fn field, acc ->
        if field["type"] == "secret",
          do: acc,
          else: Map.put(acc, field["key"], Map.get(current, field["key"]))
      end)

    %{
      slug: config.slug,
      name: config.name,
      schema: schema,
      values: stringify_values(form_data),
      form: to_form(form_data),
      env_keys: DeclaredSettings.keys(config),
      page_writes?: page_writes?(config),
      ceilings_form: ceilings_form(config)
    }
  end

  defp ceilings_form(config),
    do: to_form(Map.new(@ceiling_roles, &{&1, Grants.ceiling(config.slug, &1)}), as: :ceilings)

  # Role ceilings only mean something for a plugin whose page can write.
  defp page_writes?(config) do
    caps = capabilities_of(config)
    Map.has_key?(caps, "surfaces:write") and Map.has_key?(caps, "surfaces:page")
  end

  # Current field values keyed by string, used to resolve `visible_when`.
  defp stringify_values(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  # Extracts the schema-declared keys from submitted params. Blank secrets are
  # dropped so update_settings/2's merge preserves the existing value.
  defp build_settings(schema, params) do
    Enum.reduce(schema, %{}, fn field, acc ->
      key = field["key"]
      value = Map.get(params, key)

      cond do
        is_nil(value) -> acc
        field["type"] == "secret" and value == "" -> acc
        true -> Map.put(acc, key, value)
      end
    end)
  end

  defp load_updates(socket) do
    slugs =
      Events.list_events(category: "plugin", type: "plugin.update_available", limit: 100)
      |> Enum.map(& &1.actor_id)
      |> MapSet.new()

    assign(socket, :updates, slugs)
  end

  defp catalog_of(nil), do: []
  defp catalog_of(%BrowseResult{catalog: catalog}), do: catalog

  defp approval_from_entry(entry) do
    %{
      kind: :catalog,
      entry: entry,
      slug: entry.slug,
      name: entry.name,
      version: entry.version,
      capabilities: entry.manifest.capabilities,
      ungranted: %{},
      settings_schema:
        if(entry.manifest.multi_instance, do: [], else: entry.manifest.settings_schema)
    }
  end

  defp approval_from_config(config) do
    capabilities = capabilities_of(config)

    %{
      kind: :installed,
      slug: config.slug,
      name: config.name,
      version: config.version,
      capabilities: capabilities,
      # Non-empty only for a re-approval: the capabilities the revised manifest
      # asks for on top of what was already approved.
      ungranted:
        (Plugins.needs_reapproval?(config) && Plugins.ungranted_capabilities(config)) || %{},
      settings_schema: host_grant_schema_of(config)
    }
  end

  defp detail_for(config) do
    %{
      slug: config.slug,
      name: config.name,
      enabled: config.enabled,
      granted: config.granted_capabilities || %{},
      ungranted: Plugins.ungranted_capabilities(config),
      settings_schema: host_grant_schema_of(config)
    }
  end

  # State for the dedicated logs modal: activity log filters + Test event list.
  # The network and activity rows themselves live in streams, not here.
  defp logs_for(config) do
    %{
      slug: config.slug,
      name: config.name,
      enabled: config.enabled,
      min_level: :debug,
      query: "",
      test_events: Map.get(config.granted_capabilities || %{}, "events:subscribe", [])
    }
  end

  # Recent gated HTTP requests for the network tab, newest first.
  defp network_events(slug) do
    Events.list_events(
      type: "plugin.http_request",
      actor_type: :system,
      actor_id: slug,
      limit: @log_limit
    )
  end

  defp error_message(%{__struct__: _} = error) do
    if function_exported?(error.__struct__, :message, 1) do
      error.__struct__.message(error)
    else
      inspect(error)
    end
  end

  defp error_message(other), do: inspect(other)
end
