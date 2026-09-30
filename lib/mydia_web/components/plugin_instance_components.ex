defmodule MydiaWeb.PluginInstanceComponents do
  @moduledoc """
  Generic rendering for plugin instances: the card an instance gets on the page
  its manifest `category` places it on, and the account-link list a user sees.

  Nothing here knows which plugin it is drawing. Everything a card shows is a
  host noun (health, sync runs, approved endpoints, account links), which is
  what lets a third-party media server plugin look like the bundled ones.
  """
  use MydiaWeb, :html

  alias Mydia.Plugins.Instance

  attr :plugin, :map, required: true
  attr :instance, :map, required: true
  attr :health, :map, required: true
  attr :last_run, :any, default: nil
  attr :links, :list, default: []

  def instance_card(assigns) do
    assigns = assign(assigns, :read_only, assigns.instance.source == :runtime)

    ~H"""
    <div
      id={"plugin-instance-#{@instance.id}"}
      class={[
        "card bg-base-100 border transition-all duration-200 hover:shadow-lg",
        if(@instance.enabled,
          do: "border-base-300 hover:border-primary/30",
          else: "border-base-300/50 opacity-75"
        )
      ]}
    >
      <div class="card-body p-4 gap-4">
        <div class="flex items-start gap-3">
          <div class="p-2 sm:p-3 rounded-xl shrink-0 bg-primary/10">
            <.icon name="hero-puzzle-piece" class="w-5 h-5 sm:w-6 sm:h-6 text-primary" />
          </div>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <h3 class="font-semibold text-base truncate">{@instance.name}</h3>
              <span :if={@read_only} class="badge badge-primary badge-xs gap-1">
                <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
              </span>
            </div>
            <div class="text-xs text-base-content/50 mt-0.5">{@plugin.name} plugin</div>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span class={[
            "badge badge-sm",
            if(@instance.enabled, do: "badge-success badge-outline", else: "badge-ghost")
          ]}>
            {if @instance.enabled, do: "Active", else: "Inactive"}
          </span>
          <span class={["badge badge-sm gap-1", health_badge_class(@health.status)]}>
            {health_label(@health.status)}
          </span>
          <span :if={@health[:checked_at]} class="text-xs text-base-content/50">
            Checked {Calendar.strftime(@health.checked_at, "%H:%M")}
          </span>
        </div>

        <div :if={@health[:message] || @health[:action]} class="flex flex-wrap items-center gap-2">
          <p :if={@health[:message]} class="text-xs text-error/80 break-words flex-1">
            {@health.message}
          </p>
          <button
            :if={@health[:action] && not @read_only}
            id={"plugin-instance-health-action-#{@instance.id}"}
            class="btn btn-warning btn-xs"
            phx-click="plugin_instance_health_action"
            phx-value-id={@instance.id}
          >
            {health_action_label(@health.action)}
          </button>
        </div>

        <div :if={@last_run} class="text-xs flex items-center gap-2">
          <span class={["badge badge-xs", run_badge_class(@last_run.status)]}>
            {run_label(@last_run)}
          </span>
          <span :if={@last_run.error} class="text-error/80 break-words">{@last_run.error}</span>
        </div>

        <div :if={@instance.approved_endpoints != []} class="space-y-1">
          <p class="text-xs font-medium text-base-content/70">Approved addresses</p>
          <ul class="space-y-1">
            <li
              :for={{endpoint, index} <- Enum.with_index(@instance.approved_endpoints)}
              id={"plugin-instance-endpoint-#{@instance.id}-#{index}"}
              class="flex items-center justify-between gap-2 text-xs font-mono"
            >
              <span class="break-all">{Instance.endpoint_label(endpoint)}</span>
              <button
                :if={not @read_only}
                id={"plugin-instance-endpoint-remove-#{@instance.id}-#{index}"}
                class="btn btn-ghost btn-xs text-error"
                phx-click="plugin_instance_remove_endpoint"
                phx-value-id={@instance.id}
                phx-value-index={index}
                data-confirm="Remove this address? The plugin will no longer be able to reach it."
                aria-label="Remove address"
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            </li>
          </ul>
        </div>

        <div :if={@links != []} class="space-y-1">
          <p class="text-xs font-medium text-base-content/70">Linked accounts</p>
          <ul class="flex flex-wrap gap-1">
            <li :for={link <- @links} class={["badge badge-sm", link_badge_class(link.status)]}>
              {link.external_username || link.external_user_id}
            </li>
          </ul>
        </div>

        <p :if={@read_only} class="text-xs text-base-content/50">
          Configured via environment variables, read-only
        </p>

        <div class="flex flex-wrap items-center gap-2 pt-3 border-t border-base-200 sm:justify-end sm:gap-1 sm:pt-2">
          <button
            id={"plugin-instance-sync-#{@instance.id}"}
            class={["btn btn-ghost gap-1", action_btn()]}
            phx-click="plugin_instance_sync"
            phx-value-id={@instance.id}
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Sync now
          </button>
          <button
            id={"plugin-instance-test-#{@instance.id}"}
            class={["btn btn-ghost gap-1", action_btn()]}
            phx-click="plugin_instance_test"
            phx-value-id={@instance.id}
          >
            <.icon name="hero-signal" class="w-4 h-4" /> Test
          </button>
          <button
            :if={not @read_only and @plugin.setup}
            id={"plugin-instance-accounts-#{@instance.id}"}
            class={["btn btn-ghost gap-1", action_btn()]}
            phx-click="plugin_instance_accounts"
            phx-value-id={@instance.id}
          >
            <.icon name="hero-user-group" class="w-4 h-4" /> Accounts
          </button>
          <button
            :if={not @read_only and @plugin.setup}
            id={"plugin-instance-reconnect-#{@instance.id}"}
            class={["btn btn-ghost gap-1", action_btn()]}
            phx-click="plugin_instance_reconnect"
            phx-value-id={@instance.id}
          >
            <.icon name="hero-key" class="w-4 h-4" /> Reconnect
          </button>
          <button
            :if={not @read_only}
            id={"plugin-instance-toggle-#{@instance.id}"}
            class={["btn btn-ghost gap-1", action_btn()]}
            phx-click="plugin_instance_toggle"
            phx-value-id={@instance.id}
          >
            {if @instance.enabled, do: "Disable", else: "Enable"}
          </button>
          <button
            :if={not @read_only}
            id={"plugin-instance-delete-#{@instance.id}"}
            class={["btn btn-ghost gap-1 text-error hover:bg-error/10", action_btn()]}
            phx-click="plugin_instance_delete"
            phx-value-id={@instance.id}
            data-confirm={"Delete #{@instance.name}? Its account links and sync state are removed."}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            <span class="sm:hidden">Delete</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

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

  defp action_btn, do: "btn-sm min-h-11 sm:min-h-8"

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

  # Task 8 adds :partial for a run that finished with some item errors.
  defp run_label(%{status: :partial, counts: counts}) when is_map(counts) do
    "Partly synced: #{Map.get(counts, "errors", 0)} errors"
  end

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
