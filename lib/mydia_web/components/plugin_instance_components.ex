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
        <div>{@plugin.name} plugin</div>
        <div :if={@health[:message]} class="text-error/80 whitespace-normal break-words">
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
        <div :if={@last_run} class="whitespace-normal">
          <span class={["badge badge-xs", run_badge_class(@last_run.status)]}>
            {run_label(@last_run)}
          </span>
          <span :if={@last_run.error} class="text-error/80 break-words">{@last_run.error}</span>
        </div>
        <ul :if={@instance.approved_endpoints != []} class="whitespace-normal font-mono">
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
              data-confirm="Remove this address? The plugin will no longer be able to reach it."
              aria-label="Remove address"
            >
              <.icon name="hero-x-mark" class="w-3 h-3" />
            </button>
          </li>
        </ul>
        <ul :if={@links != []} class="flex flex-wrap gap-1 whitespace-normal mt-1">
          <li
            :for={link <- @links}
            class={["badge badge-sm", link_badge_class(link.status)]}
          >
            {link.external_username || link.external_user_id}
          </li>
        </ul>
        <div :if={@read_only}>Configured via environment variables, read-only</div>
      </:descriptor>
      <:badges>
        <span class={[
          "badge badge-sm badge-outline",
          if(@instance.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @instance.enabled, do: "Active", else: "Inactive"}
        </span>
        <span class={[
          "badge badge-sm badge-outline gap-1",
          health_badge_class(@health.status)
        ]}>
          {health_label(@health.status)}
        </span>
        <span :if={@health[:checked_at]} class="text-xs text-base-content/50">
          Checked {Calendar.strftime(@health.checked_at, "%H:%M")}
        </span>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"plugin-instance-sync-#{@instance.id}"}
            icon="hero-arrow-path"
            title="Sync now"
            phx-click="plugin_instance_sync"
            phx-value-id={@instance.id}
          />
          <.row_action
            id={"plugin-instance-test-#{@instance.id}"}
            icon="hero-signal"
            title="Test"
            phx-click="plugin_instance_test"
            phx-value-id={@instance.id}
          />
          <.row_action
            :if={@plugin.setup}
            id={"plugin-instance-accounts-#{@instance.id}"}
            icon="hero-user-group"
            title="Accounts"
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_reason())}
            phx-click="plugin_instance_accounts"
            phx-value-id={@instance.id}
          />
          <.row_action
            :if={@plugin.setup}
            id={"plugin-instance-reconnect-#{@instance.id}"}
            icon="hero-key"
            title="Reconnect"
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_reason())}
            phx-click="plugin_instance_reconnect"
            phx-value-id={@instance.id}
          />
          <.row_action
            id={"plugin-instance-toggle-#{@instance.id}"}
            icon="hero-power"
            title={if(@instance.enabled, do: "Disable", else: "Enable")}
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_reason())}
            phx-click="plugin_instance_toggle"
            phx-value-id={@instance.id}
          />
          <.row_action
            id={"plugin-instance-delete-#{@instance.id}"}
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@read_only}
            disabled_reason={if(@read_only, do: env_reason())}
            phx-click="plugin_instance_delete"
            phx-value-id={@instance.id}
            data-confirm={"Delete #{@instance.name}? Its account links and sync state are removed."}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  defp env_reason, do: "Configured via environment variables (read-only)"

  attr :declarations, :list, required: true

  def plex_deprecation_banner(assigns) do
    ~H"""
    <div :if={@declarations != []} id="plex-deprecation-banner" class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <div class="text-sm space-y-1">
        <p class="font-medium">Plex is now configured as a plugin.</p>
        <p>
          These servers still work, but they are declared through
          <code>MEDIA_SERVER_&lt;N&gt;_*</code>
          or <code>media_servers:</code>, which will
          stop being read for Plex in a future release:
        </p>
        <ul class="list-disc ml-5">
          <li :for={decl <- @declarations}>{decl.name}</li>
        </ul>
        <p>
          Rename them to <code>PLUGIN_PLEX_&lt;N&gt;_NAME</code>,
          <code>PLUGIN_PLEX_&lt;N&gt;_URL</code>
          and <code>PLUGIN_PLEX_&lt;N&gt;_TOKEN</code>,
          or move them to a <code>plugin_instances:</code>
          entry with <code>plugin: plex</code>.
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
      <h3 class="font-semibold">Linked accounts</h3>
      <p class="text-sm text-base-content/70">
        An administrator linked these accounts to you. Watch history syncs for each of them.
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
              on {link.instance.name} ({Map.get(@plugin_names, link.plugin_slug, link.plugin_slug)})
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

  defp health_label(:ok), do: "Healthy"
  defp health_label(:degraded), do: "Degraded"
  defp health_label(:unauthorized), do: "Sign-in expired"
  defp health_label(:unreachable), do: "Unreachable"
  defp health_label(:disabled), do: "Disabled"
  defp health_label(:unsupported), do: "No health check"
  defp health_label(_), do: "Unknown"

  defp health_badge_class(:ok), do: "badge-success"
  defp health_badge_class(:degraded), do: "badge-warning"
  defp health_badge_class(:unauthorized), do: "badge-error"
  defp health_badge_class(:unreachable), do: "badge-error"
  defp health_badge_class(_), do: "badge-ghost"

  defp health_action_label(:reconnect), do: "Reconnect"
  defp health_action_label(:confirm_endpoints), do: "Confirm new addresses"

  defp run_badge_class(:ok), do: "badge-success"
  defp run_badge_class(:partial), do: "badge-warning"
  defp run_badge_class(:error), do: "badge-error"
  defp run_badge_class(:skipped), do: "badge-warning"
  defp run_badge_class(_), do: "badge-ghost"

  defp run_label(%{status: :ok, counts: counts}) when is_map(counts) do
    "Synced: pulled #{Map.get(counts, "pulled", 0)}, pushed #{Map.get(counts, "pushed", 0)}"
  end

  # A partial run finished with some item errors. The counts may lack "errors".
  defp run_label(%{status: :partial, counts: %{"errors" => errors}})
       when is_integer(errors) and errors > 0,
       do: "Partly synced: #{errors} errors"

  defp run_label(%{status: :partial}), do: "Partly synced"

  defp run_label(%{status: :skipped}), do: "Skipped"
  defp run_label(%{status: :error}), do: "Failed"
  defp run_label(_), do: "Ran"

  defp link_badge_class(:active), do: "badge-success badge-outline"
  defp link_badge_class(:error), do: "badge-error"
  defp link_badge_class(_), do: "badge-ghost"

  defp link_status_label(:active), do: "Active"
  defp link_status_label(:error), do: "Needs attention"
  defp link_status_label(_), do: "Paused"
end
