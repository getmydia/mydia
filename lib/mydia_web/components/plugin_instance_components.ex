defmodule MydiaWeb.PluginInstanceComponents do
  @moduledoc """
  Generic rendering for plugin instances: the row an instance gets on the page
  its manifest `category` places it on, and the account-link list a user sees.

  Nothing here knows which plugin it is drawing. Everything a card shows is a
  host noun (health, sync runs, approved endpoints, account links), which is
  what lets a third-party media server plugin look like the bundled ones.
  """
  use MydiaWeb, :html

  alias Mydia.Plugins.Instance

  @doc "One plugin-backed media server as an admin_row/1."
  attr :display, Mydia.TimeDisplay, required: true
  attr :plugin, :map, required: true
  attr :instance, :map, required: true
  attr :health, :map, required: true
  attr :last_run, :any, default: nil
  attr :links, :list, default: []

  def plugin_instance_row(assigns) do
    assigns = assign(assigns, :read_only, assigns.instance.source == :runtime)

    ~H"""
    <.admin_row
      id={"plugin-instance-#{@instance.id}"}
      class={if(not @instance.enabled, do: "opacity-60")}
    >
      <:title>
        <.icon name="hero-puzzle-piece" class="w-5 h-5 text-base-content/60" />
        {@instance.name}
        <.env_lock_badge :if={@read_only} />
      </:title>
      <:descriptor>
        {gettext("%{name} plugin", name: @plugin.name)}
      </:descriptor>
      <:details>
        <div :if={@health[:message]} class="text-error/80 break-words">
          {@health.message}
        </div>
        <button
          :if={@health[:action] && not @read_only}
          id={"plugin-instance-health-action-#{@instance.id}"}
          class="btn btn-warning btn-xs my-1"
          phx-click="plugin_instance_health_action"
          phx-value-id={@instance.id}
        >
          {health_action_label(@health.action)}
        </button>
        <div :if={@last_run}>
          <span class={["badge badge-xs", run_badge_class(@last_run.status)]}>
            {run_label(@last_run)}
          </span>
          <span :if={@last_run.error} class="text-error/80 break-words">{@last_run.error}</span>
        </div>
        <ul :if={@instance.approved_endpoints != []} class="font-mono">
          <li
            :for={{endpoint, index} <- Enum.with_index(@instance.approved_endpoints)}
            id={"plugin-instance-endpoint-#{@instance.id}-#{index}"}
            class="flex items-center gap-2"
          >
            <span class="break-all">{Instance.endpoint_label(endpoint)}</span>
            <button
              :if={not @read_only}
              id={"plugin-instance-endpoint-remove-#{@instance.id}-#{index}"}
              class="btn btn-ghost btn-xs text-error"
              phx-click="plugin_instance_remove_endpoint"
              phx-value-id={@instance.id}
              phx-value-scheme={endpoint["scheme"]}
              phx-value-host={endpoint["host"]}
              phx-value-port={endpoint["port"]}
              data-confirm={
                gettext("Remove this address? The plugin will no longer be able to reach it.")
              }
              aria-label={gettext("Remove address")}
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </li>
        </ul>
        <ul :if={@links != []} class="flex flex-wrap gap-1">
          <li
            :for={link <- @links}
            class={["badge badge-sm", link_badge_class(link.status)]}
          >
            {link.external_username || link.external_user_id}
          </li>
        </ul>
        <div :if={@read_only}>{gettext("Configured via environment variables, read-only")}</div>
      </:details>
      <:badges>
        <span class={[
          "badge badge-sm badge-outline",
          if(@instance.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @instance.enabled,
            do: pgettext("plugin instance", "Active"),
            else: pgettext("plugin instance", "Inactive")}
        </span>
        <span class={[
          "badge badge-sm badge-outline gap-1",
          health_badge_class(@health.status)
        ]}>
          {health_label(@health.status)}
        </span>
        <span :if={@health[:checked_at]} class="text-xs text-base-content/50">
          {gettext("Checked %{time}", time: format(@health.checked_at, :time, @display))}
        </span>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"plugin-instance-sync-#{@instance.id}"}
            icon="hero-arrow-path"
            title={gettext("Sync now")}
            phx-click="plugin_instance_sync"
            phx-value-id={@instance.id}
          />
          <.row_action
            id={"plugin-instance-test-#{@instance.id}"}
            icon="hero-signal"
            title={pgettext("plugin instance", "Test")}
            phx-click="plugin_instance_test"
            phx-value-id={@instance.id}
          />
          <.row_action
            :if={@plugin.setup}
            id={"plugin-instance-accounts-#{@instance.id}"}
            icon="hero-user-group"
            title={gettext("Accounts")}
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_read_only_reason())}
            phx-click="plugin_instance_accounts"
            phx-value-id={@instance.id}
          />
          <.row_action
            :if={@plugin.setup}
            id={"plugin-instance-reconnect-#{@instance.id}"}
            icon="hero-key"
            title={gettext("Reconnect")}
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_read_only_reason())}
            phx-click="plugin_instance_reconnect"
            phx-value-id={@instance.id}
          />
          <.row_action
            id={"plugin-instance-toggle-#{@instance.id}"}
            icon="hero-power"
            title={
              if(@instance.enabled,
                do: pgettext("plugin instance", "Disable"),
                else: pgettext("plugin instance", "Enable")
              )
            }
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_read_only_reason())}
            phx-click="plugin_instance_toggle"
            phx-value-id={@instance.id}
          />
          <.row_action
            id={"plugin-instance-delete-#{@instance.id}"}
            icon="hero-trash"
            title={gettext("Delete")}
            destructive
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_read_only_reason())}
            phx-click="plugin_instance_delete"
            phx-value-id={@instance.id}
            data-confirm={
              gettext("Delete %{name}? Its account links and sync state are removed.",
                name: @instance.name
              )
            }
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :declarations, :list, required: true

  def plex_deprecation_banner(assigns) do
    ~H"""
    <div :if={@declarations != []} id="plex-deprecation-banner" class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div class="text-sm space-y-1">
        <p class="font-medium">{gettext("Plex is now configured as a plugin.")}</p>
        <p>
          {gettext(
            "These servers still work, but they are declared through %{env} or %{yaml}, which will stop being read for Plex in a future release:",
            env: "MEDIA_SERVER_<N>_*",
            yaml: "media_servers:"
          )}
        </p>
        <ul class="list-disc ml-5">
          <li :for={decl <- @declarations}>{decl.name}</li>
        </ul>
        <p>
          {gettext(
            "Rename them to %{name}, %{url} and %{token}, or move them to a %{section} entry with %{plugin}.",
            name: "PLUGIN_PLEX_<N>_NAME",
            url: "PLUGIN_PLEX_<N>_URL",
            token: "PLUGIN_PLEX_<N>_TOKEN",
            section: "plugin_instances:",
            plugin: "plugin: plex"
          )}
        </p>
      </div>
    </div>
    """
  end

  attr :links, :list, required: true
  attr :plugin_names, :map, default: %{}

  def account_links_list(assigns) do
    ~H"""
    <div :if={@links != []} id="account-links" class="space-y-2">
      <h3 class="font-semibold">{gettext("Linked accounts")}</h3>
      <p class="text-sm text-base-content/70">
        {gettext(
          "An administrator linked these accounts to you. Watch history syncs for each of them."
        )}
      </p>
      <ul class="divide-y divide-base-200">
        <li
          :for={link <- @links}
          id={"account-link-#{link.id}"}
          class="flex items-center justify-between gap-2 py-2 text-sm"
        >
          <span>
            <span class="font-medium">{link.external_username || link.external_user_id}</span>
            <span class="text-base-content/60">
              {gettext("on %{instance} (%{plugin})",
                instance: link.instance.name,
                plugin: Map.get(@plugin_names, link.plugin_slug, link.plugin_slug)
              )}
            </span>
          </span>
          <span class={["badge badge-sm", link_badge_class(link.status)]}>
            {link_status_label(link.status)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp health_label(:ok), do: gettext("Healthy")
  defp health_label(:degraded), do: gettext("Degraded")
  defp health_label(:unauthorized), do: gettext("Sign-in expired")
  defp health_label(:unreachable), do: gettext("Unreachable")
  defp health_label(:disabled), do: pgettext("plugin instance", "Disabled")
  defp health_label(:unsupported), do: gettext("No health check")
  defp health_label(_), do: gettext("Unknown")

  defp health_badge_class(:ok), do: "badge-success"
  defp health_badge_class(:degraded), do: "badge-warning"
  defp health_badge_class(:unauthorized), do: "badge-error"
  defp health_badge_class(:unreachable), do: "badge-error"
  defp health_badge_class(_), do: "badge-ghost"

  defp health_action_label(:reconnect), do: gettext("Reconnect")
  defp health_action_label(:confirm_endpoints), do: gettext("Confirm new addresses")

  defp run_badge_class(:ok), do: "badge-success"
  defp run_badge_class(:partial), do: "badge-warning"
  defp run_badge_class(:error), do: "badge-error"
  defp run_badge_class(:skipped), do: "badge-warning"
  defp run_badge_class(_), do: "badge-ghost"

  defp run_label(%{status: :ok, counts: counts}) when is_map(counts) do
    gettext("Synced: pulled %{pulled}, pushed %{pushed}",
      pulled: Map.get(counts, "pulled", 0),
      pushed: Map.get(counts, "pushed", 0)
    )
  end

  # A partial run finished with some item errors. The counts may lack "errors".
  defp run_label(%{status: :partial, counts: %{"errors" => errors}})
       when is_integer(errors) and errors > 0,
       do: ngettext("Partly synced: %{count} error", "Partly synced: %{count} errors", errors)

  defp run_label(%{status: :partial}), do: gettext("Partly synced")

  defp run_label(%{status: :skipped}), do: gettext("Skipped")
  defp run_label(%{status: :error}), do: gettext("Failed")
  defp run_label(_), do: gettext("Ran")

  defp link_badge_class(:active), do: "badge-success badge-outline"
  defp link_badge_class(:error), do: "badge-error"
  defp link_badge_class(_), do: "badge-ghost"

  defp link_status_label(:active), do: pgettext("plugin instance", "Active")
  defp link_status_label(:error), do: gettext("Needs attention")
  defp link_status_label(_), do: pgettext("monitoring", "Paused")
end
