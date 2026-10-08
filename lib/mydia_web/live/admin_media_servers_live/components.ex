defmodule MydiaWeb.AdminMediaServersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings
  alias MydiaWeb.PluginInstanceComponents

  @doc """
  Renders the Media Servers tab content: the Plex deprecation banner, the
  Jellyfin servers and the plugin-backed servers.
  """
  attr :media_servers, :list, required: true
  attr :media_server_health, :map, required: true
  attr :last_runs, :map, default: %{}
  attr :link_counts, :map, default: %{}
  attr :plex_deprecations, :list, default: []
  attr :plugin_instances, :list, default: []
  attr :plugin_instance_health, :map, default: %{}
  attr :plugin_instance_runs, :map, default: %{}
  attr :plugin_instance_links, :map, default: %{}

  def media_servers_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <PluginInstanceComponents.plex_deprecation_banner declarations={@plex_deprecations} />

      <.admin_list
        :if={@media_servers != [] or @plugin_instances == []}
        id="media-servers"
        items={@media_servers}
      >
        <:row :let={server}>
          <.media_server_row
            server={server}
            health={Map.get(@media_server_health, server.id, %{status: :unknown})}
            last_run={Map.get(@last_runs, server.id)}
            link_count={Map.get(@link_counts, server.id, 0)}
          />
        </:row>
        <:empty>
          <span class="block font-semibold">No media servers connected</span>
          <span class="block mt-1">
            Connect a server, or add one from the Add server menu, and Mydia
            refreshes its library as soon as an import finishes, so new episodes show up
            without waiting for the server's next scheduled scan. Both also sync watched
            status in both directions, mapped separately for each account on the server
            so nobody inherits anyone else's history.
          </span>
          <button
            id="media-servers-empty-cta"
            class="btn btn-sm btn-primary mt-3"
            phx-click="new_media_server"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Connect a server
          </button>
        </:empty>
      </.admin_list>

      <.admin_section
        :if={@plugin_instances != []}
        id="plugin-servers"
        title="Plugin servers"
        icon="hero-puzzle-piece"
        count={length(@plugin_instances)}
      >
        <.admin_list id="plugin-media-servers" items={@plugin_instances}>
          <:row :let={{plugin, instance}}>
            <PluginInstanceComponents.plugin_instance_row
              plugin={plugin}
              instance={instance}
              health={Map.get(@plugin_instance_health, instance.id, %{status: :unknown})}
              last_run={Map.get(@plugin_instance_runs, instance.id)}
              links={Map.get(@plugin_instance_links, instance.id, [])}
            />
          </:row>
          <:empty>No plugin servers.</:empty>
        </.admin_list>
      </.admin_section>
    </div>
    """
  end

  attr :server, :map, required: true
  attr :health, :map, required: true
  attr :last_run, :any, default: nil
  attr :link_count, :integer, default: 0

  defp media_server_row(assigns) do
    settings = assigns.server.connection_settings || %{}

    assigns =
      assigns
      |> assign(:runtime?, Settings.runtime_config?(assigns.server))
      |> assign(:sync_enabled?, get_in(settings, ["sync_watched"]) in [true, "true"])
      |> assign(:last_sync, get_in(settings, ["last_watched_sync_at"]))

    ~H"""
    <.admin_row id={"media-server-#{@server.id}"} class={if(not @server.enabled, do: "opacity-60")}>
      <:title>
        <.icon name={media_server_type_icon(@server.type)} class="w-5 h-5 text-base-content/60" />
        {@server.name}
        <.env_lock_badge :if={@runtime?} />
      </:title>
      <:descriptor>
        <span class="font-mono">{@server.url}</span>
      </:descriptor>
      <:details>
        <div
          :if={@health[:error]}
          data-test="health-error"
          title={@health.error}
          class="text-error/80 break-words"
        >
          {@health.error}
        </div>
        <div :if={@sync_enabled?} data-test="watched-sync-enabled">
          Watched sync enabled
          <%= if @last_sync do %>
            &middot; Last synced {@last_sync}
          <% end %>
        </div>
        <.last_run_lines :if={@last_run} server={@server} last_run={@last_run} />
        <div :if={@runtime?} data-test="env-config-note">
          Configured via environment variables, read-only
        </div>
      </:details>
      <:badges>
        <span class="badge badge-sm badge-outline">{media_server_type_label(@server.type)}</span>
        <span class={[
          "badge badge-sm badge-outline",
          if(@server.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @server.enabled, do: "Active", else: "Inactive"}
        </span>
        <span
          role="img"
          aria-label={health_status_label(@health.status)}
          class={["badge badge-sm badge-outline gap-1", health_status_badge_class(@health.status)]}
        >
          <.icon name={health_status_icon(@health.status)} class="w-3 h-3" />
          {health_status_label(@health.status)}
        </span>
        <span :if={@link_count > 0} class="badge badge-sm badge-outline">
          {@link_count} {if @link_count == 1, do: "account", else: "accounts"}
        </span>
        <span :if={@health[:checked_at]} class="text-xs text-base-content/50">
          Checked {Calendar.strftime(@health.checked_at, "%H:%M")}
        </span>
      </:badges>
      <:actions>
        <.row_actions>
          <%= if @sync_enabled? and @server.type == :jellyfin do %>
            <.row_action
              icon="hero-user-group"
              title={if(@link_count > 0, do: "Accounts (#{@link_count})", else: "Accounts")}
              data-test="map-accounts"
              disabled={@runtime?}
              disabled_reason={if(@runtime?, do: "Account mapping needs a database-managed server")}
              phx-click="open_account_mapping"
              phx-value-id={@server.id}
            />
            <.row_action
              icon="hero-arrow-path"
              title="Sync now"
              phx-click="sync_watched"
              phx-value-id={@server.id}
            />
          <% end %>
          <.row_action
            icon="hero-signal"
            title="Test"
            phx-click="test_media_server"
            phx-value-id={@server.id}
          />
          <.row_action
            icon="hero-pencil"
            title="Edit"
            disabled={@runtime?}
            disabled_reason={if(@runtime?, do: env_read_only_reason())}
            phx-click="edit_media_server"
            phx-value-id={@server.id}
          />
          <.row_action
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@runtime?}
            disabled_reason={if(@runtime?, do: env_read_only_reason())}
            phx-click="delete_media_server"
            phx-value-id={@server.id}
            data-confirm="Are you sure you want to delete this media server?"
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :server, :map, required: true
  attr :last_run, :map, required: true

  defp last_run_lines(assigns) do
    ~H"""
    <div data-test="last-sync-run" class="space-y-0.5">
      <span class={[
        "badge badge-xs",
        @last_run.status == :ok && "badge-success",
        @last_run.status == :error && "badge-error",
        @last_run.status == :skipped && "badge-warning"
      ]}>
        {run_label(@last_run)}
      </span>
      <div :if={@last_run.status == :skipped} id={"sync-skip-#{@server.id}"} class="text-warning">
        {humanize_skip(@last_run.skip_reason)}
      </div>
      <div
        :if={@last_run.status == :error && @last_run.error}
        id={"sync-error-#{@server.id}"}
        class="text-error/80 break-words"
      >
        {@last_run.error}
      </div>
    </div>
    """
  end

  @doc """
  The page header's Add server menu: the native Jellyfin form plus one entry per
  media server plugin. The Jellyfin entry keeps the `new-media-server` id the
  page has always had.
  """
  attr :media_server_plugins, :list, default: []

  def header_actions(assigns) do
    ~H"""
    <div id="add-server-menu" class="dropdown dropdown-end w-full sm:w-auto">
      <div tabindex="0" role="button" class="btn btn-sm btn-primary">
        <.icon name="hero-plus" class="w-4 h-4" /> Add server
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-10 w-56 p-2 shadow border border-base-300"
      >
        <li :for={plugin <- @media_server_plugins}>
          <button
            id={"add-server-plugin-#{plugin.slug}"}
            phx-click="add_plugin_server"
            phx-value-slug={plugin.slug}
            onclick="document.activeElement && document.activeElement.blur()"
          >
            {plugin.name}
          </button>
        </li>
        <li>
          <button
            id="new-media-server"
            phx-click="new_media_server"
            onclick="document.activeElement && document.activeElement.blur()"
          >
            Jellyfin
          </button>
        </li>
      </ul>
    </div>
    """
  end

  # Media server type helpers
  @doc false
  def media_server_type_icon(:jellyfin), do: "hero-tv"
  def media_server_type_icon(_), do: "hero-server"

  defp media_server_type_label(:jellyfin), do: "Jellyfin"

  defp media_server_type_label(type) when is_atom(type),
    do: Atom.to_string(type) |> String.capitalize()

  defp media_server_type_label(type), do: to_string(type)

  defp health_status_badge_class(:healthy), do: "badge-success"
  defp health_status_badge_class(:unhealthy), do: "badge-error"
  defp health_status_badge_class(:unknown), do: "badge-ghost"
  defp health_status_badge_class(:disabled), do: "badge-ghost"

  defp health_status_icon(:healthy), do: "hero-check-circle"
  defp health_status_icon(:unhealthy), do: "hero-x-circle"
  defp health_status_icon(:unknown), do: "hero-question-mark-circle"
  defp health_status_icon(:disabled), do: "hero-pause-circle"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unknown), do: "Unknown"
  defp health_status_label(:disabled), do: "Disabled"

  defp run_label(%{status: :skipped, skip_reason: reason}) when is_binary(reason) do
    skip_reason_label(reason)
  end

  # A skipped run with no reason recorded still has to read as skipped. Without
  # this the clause below catches it and the badge says "Failed", which is the
  # one thing it definitely was not.
  defp run_label(%{status: :skipped}), do: "Skipped"

  defp run_label(%{status: :ok, counts: counts}) when is_map(counts) do
    imported = Map.get(counts, "imported") || Map.get(counts, :imported) || 0
    exported = Map.get(counts, "exported") || Map.get(counts, :exported) || 0
    "Synced #{imported} in, #{exported} out"
  end

  defp run_label(%{status: :error}), do: "Failed"
  defp run_label(_), do: "Failed"

  # The short badge label. sync_runs rows outlive the code that wrote them, so
  # every reason ever recorded needs a label here.
  #
  # Kept deliberately provider-neutral.
  defp skip_reason_label("server_disabled"), do: "Server is disabled"
  defp skip_reason_label("sync_disabled"), do: "Watched sync is off"
  defp skip_reason_label("unsupported_provider"), do: "Watched sync not supported"
  defp skip_reason_label("no_user_mapping"), do: "No users linked yet"
  defp skip_reason_label("seeding_links"), do: "Linking accounts to Mydia users"
  defp skip_reason_label("no_matching_users"), do: "Nothing new to link"
  defp skip_reason_label("link_seeding_failed"), do: "Could not reach the server to link users"
  # Recorded by an earlier release that could pause a single mapping. Kept
  # because sync_runs rows outlive the code that wrote them.
  defp skip_reason_label("all_mappings_paused"), do: "Every mapping is paused"
  defp skip_reason_label("no_token"), do: "No API token configured"
  defp skip_reason_label("link_user_mismatch"), do: "A user mapping points at the wrong account"
  defp skip_reason_label("link_identity_missing"), do: "A user mapping is incomplete"
  defp skip_reason_label("link_not_found"), do: "The user mapping was deleted"
  defp skip_reason_label("missing_user_token"), do: "A user mapping has no token"
  defp skip_reason_label("missing_remote_user_id"), do: "A user mapping names no account"
  defp skip_reason_label(other), do: "Skipped: #{other}"

  # The badge above is a few words; this is the operator-facing detail line
  # under it, which says what to actually do about it. It is what tells someone
  # "watched sync is turned off" apart from "nobody is mapped yet", which the
  # badge alone cannot. New reasons should get their own clause here rather than
  # falling through, but the fallback keeps a future reason from crashing or
  # rendering blank.
  defp humanize_skip("server_disabled"), do: "This server is disabled, so sync did not run."
  defp humanize_skip("sync_disabled"), do: "Watched sync is turned off for this server."

  defp humanize_skip("unsupported_provider"),
    do: "This server type does not support watched sync."

  defp humanize_skip("no_user_mapping"),
    do: "No Mydia users are mapped to accounts on this server. Press Accounts to map them."

  defp humanize_skip("all_mappings_paused"),
    do:
      "Every user mapping on this server was paused, so there was nobody to sync. Press Accounts to review them."

  defp humanize_skip("seeding_links"),
    do: "Linking this server's accounts to Mydia users. Sync runs again once that finishes."

  # Reached whenever a seeding pass wrote no new link, which covers an account
  # matching nobody and an account whose Mydia user is already mapped. Telling
  # the operator to map accounts by hand is wrong in the second case, where the
  # mapping they want already exists.
  defp humanize_skip("no_matching_users"),
    do:
      "Nothing new was linked. Either no account matched a Mydia username, or the ones that did are already mapped. Press Accounts to check."

  defp humanize_skip("link_seeding_failed"),
    do: "Could not reach the server to link users. This retries on the next run."

  defp humanize_skip("no_token"),
    do: "This server has no API token, so sync could not authenticate. Add one and save."

  defp humanize_skip("link_user_mismatch"),
    do: "A user mapping points at the wrong account. Press Accounts to fix it."

  defp humanize_skip("link_identity_missing"),
    do: "A user mapping is missing its account on this server. Press Accounts to fix it."

  defp humanize_skip("link_not_found"),
    do: "The user mapping used for this run was deleted. Press Accounts to map the user again."

  defp humanize_skip("missing_user_token"),
    do:
      "A user mapping has no token of its own, so the sync would have read the server owner's account. Press Accounts and save the mapping again to mint one."

  defp humanize_skip("missing_remote_user_id"),
    do: "A user mapping does not name an account on this server. Press Accounts to fix it."

  defp humanize_skip(other), do: other
end
