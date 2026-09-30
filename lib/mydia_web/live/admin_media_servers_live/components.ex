defmodule MydiaWeb.AdminMediaServersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings

  @doc """
  Renders the Media Servers tab content.
  """
  attr :media_servers, :list, required: true
  attr :media_server_health, :map, required: true
  attr :last_runs, :map, default: %{}
  attr :link_counts, :map, default: %{}
  attr :has_plugin_instances, :boolean, default: false

  def media_servers_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <%= if @media_servers == [] and not @has_plugin_instances do %>
        <div
          id="media-servers-empty"
          class="card bg-base-100 border border-base-300"
        >
          <div class="card-body items-center text-center gap-3 py-10">
            <div class="bg-primary/10 p-4 rounded-full">
              <.icon name="hero-server-stack" class="w-8 h-8 text-primary" />
            </div>
            <h3 class="font-semibold text-lg">No media servers connected</h3>
            <p class="text-sm text-base-content/70 max-w-md">
              Connect a server, or add one from the Add server menu, and Mydia
              refreshes its library as soon as an import finishes, so new episodes show up
              without waiting for the server's next scheduled scan.
            </p>
            <p class="text-sm text-base-content/70 max-w-md">
              Both also sync watched status in both directions, mapped separately for each
              account on the server so nobody inherits anyone else's history.
            </p>
            <button
              id="media-servers-empty-cta"
              class="btn btn-primary mt-2 min-h-11 sm:min-h-8"
              phx-click="new_media_server"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Connect a server
            </button>
          </div>
        </div>
      <% else %>
        <%!-- Server Cards Grid --%>
        <div class="grid gap-4 md:grid-cols-2">
          <%= for server <- @media_servers do %>
            <% health = Map.get(@media_server_health, server.id, %{status: :unknown}) %>
            <% is_runtime = Settings.runtime_config?(server) %>
            <% last_run = Map.get(@last_runs, server.id) %>

            <div class={[
              "card bg-base-100 border transition-all duration-200 hover:shadow-lg",
              if(server.enabled,
                do: "border-base-300 hover:border-primary/30",
                else: "border-base-300/50 opacity-75"
              )
            ]}>
              <div class="card-body p-4 gap-4">
                <%!-- Top Row: Icon + Name + Status --%>
                <div class="flex items-start gap-3">
                  <%!-- Server Type Icon --%>
                  <div class={[
                    "p-2 sm:p-3 rounded-xl shrink-0",
                    media_server_type_bg_class(server.type)
                  ]}>
                    <.icon
                      name={media_server_type_icon(server.type)}
                      class={"w-5 h-5 sm:w-6 sm:h-6 #{media_server_type_icon_class(server.type)}"}
                    />
                  </div>

                  <%!-- Server Info --%>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2 flex-wrap">
                      <h3 class="font-semibold text-base truncate">{server.name}</h3>
                      <%= if is_runtime do %>
                        <span class="badge badge-primary badge-xs gap-1">
                          <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                        </span>
                      <% end %>
                    </div>
                    <div class="text-xs text-base-content/50 mt-0.5 font-mono break-all sm:truncate">
                      {server.url}
                    </div>
                  </div>

                  <%!-- Health Status Indicator --%>
                  <div
                    role="img"
                    aria-label={health_status_label(health.status)}
                    class={[
                      "w-3 h-3 rounded-full shrink-0 mt-1",
                      health_status_dot_class(health.status)
                    ]}
                  >
                  </div>
                </div>

                <%!-- Middle Row: Badges --%>
                <div class="flex flex-wrap items-center gap-2">
                  <span class={[
                    "badge badge-sm gap-1",
                    media_server_type_badge_class(server.type)
                  ]}>
                    {media_server_type_label(server.type)}
                  </span>
                  <span class={[
                    "badge badge-sm",
                    if(server.enabled, do: "badge-success badge-outline", else: "badge-ghost")
                  ]}>
                    {if server.enabled, do: "Active", else: "Inactive"}
                  </span>
                  <span class={[
                    "badge badge-sm gap-1",
                    health_status_badge_class(health.status)
                  ]}>
                    <.icon name={health_status_icon(health.status)} class="w-3 h-3" />
                    {health_status_label(health.status)}
                  </span>
                  <span :if={health[:checked_at]} class="text-xs text-base-content/50">
                    Checked {Calendar.strftime(health.checked_at, "%H:%M")}
                  </span>
                </div>

                <p
                  :if={health[:error]}
                  data-test="health-error"
                  title={health.error}
                  class="text-xs text-error/80 break-words"
                >
                  {health.error}
                </p>

                <%!-- Watched Sync Status --%>
                <% sync_enabled =
                  get_in(server.connection_settings || %{}, ["sync_watched"]) in [true, "true"] %>
                <% last_sync = get_in(server.connection_settings || %{}, ["last_watched_sync_at"]) %>
                <%= if sync_enabled do %>
                  <div
                    data-test="watched-sync-enabled"
                    class="flex items-center gap-2 text-xs text-base-content/60"
                  >
                    <.icon name="hero-arrow-path" class="w-3.5 h-3.5" />
                    <span>
                      Watched sync enabled
                      <%= if last_sync do %>
                        &middot; Last synced {last_sync}
                      <% end %>
                    </span>
                  </div>
                <% end %>

                <div
                  :if={last_run}
                  data-test="last-sync-run"
                  class="flex flex-col gap-1 text-xs"
                >
                  <div class="flex items-center gap-2">
                    <span class={[
                      "badge badge-xs",
                      last_run.status == :ok && "badge-success",
                      last_run.status == :error && "badge-error",
                      last_run.status == :skipped && "badge-warning"
                    ]}>
                      {run_label(last_run)}
                    </span>
                  </div>
                  <div
                    :if={last_run.status == :skipped}
                    id={"sync-skip-#{server.id}"}
                    class="text-warning"
                  >
                    {humanize_skip(last_run.skip_reason)}
                  </div>
                  <div
                    :if={last_run.status == :error && last_run.error}
                    id={"sync-error-#{server.id}"}
                    class="text-error/80 break-words"
                  >
                    {last_run.error}
                  </div>
                </div>

                <p
                  :if={is_runtime}
                  data-test="env-config-note"
                  class="text-xs text-base-content/50"
                >
                  Configured via environment variables, read-only
                </p>

                <%!-- Bottom Row: Actions --%>
                <div class="flex flex-wrap items-center gap-2 pt-3 border-t border-base-200 sm:justify-end sm:gap-1 sm:pt-2">
                  <%= if sync_enabled and server.type == :jellyfin do %>
                    <button
                      data-test="map-accounts"
                      class={["btn btn-ghost gap-1", card_action_btn()]}
                      phx-click="open_account_mapping"
                      phx-value-id={server.id}
                    >
                      <.icon name="hero-user-group" class="w-4 h-4" /> Accounts
                      <span :if={Map.get(@link_counts, server.id, 0) > 0} class="badge badge-sm">
                        {Map.get(@link_counts, server.id, 0)}
                      </span>
                    </button>
                    <button
                      class={["btn btn-ghost gap-1", card_action_btn()]}
                      phx-click="sync_watched"
                      phx-value-id={server.id}
                    >
                      <.icon name="hero-arrow-path" class="w-4 h-4" /> Sync Now
                    </button>
                  <% end %>
                  <button
                    class={["btn btn-ghost gap-1", card_action_btn()]}
                    phx-click="test_media_server"
                    phx-value-id={server.id}
                  >
                    <.icon name="hero-signal" class="w-4 h-4" /> Test
                  </button>
                  <button
                    :if={not is_runtime}
                    class={["btn btn-ghost gap-1", card_action_btn()]}
                    phx-click="edit_media_server"
                    phx-value-id={server.id}
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" />
                    <span class="sm:hidden">Edit</span>
                  </button>
                  <button
                    :if={not is_runtime}
                    class={["btn btn-ghost gap-1 text-error hover:bg-error/10", card_action_btn()]}
                    phx-click="delete_media_server"
                    phx-value-id={server.id}
                    data-confirm="Are you sure you want to delete this media server?"
                  >
                    <.icon name="hero-trash" class="w-4 h-4" />
                    <span class="sm:hidden">Delete</span>
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
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
      <div
        tabindex="0"
        role="button"
        class="btn btn-primary w-full min-h-11 sm:btn-sm sm:w-auto sm:min-h-8"
      >
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

  defp media_server_type_badge_class(:jellyfin), do: "badge-info"
  defp media_server_type_badge_class(_), do: "badge-ghost"

  @doc false
  def media_server_type_bg_class(:jellyfin), do: "bg-info/10"
  def media_server_type_bg_class(_), do: "bg-base-300"

  @doc false
  def media_server_type_icon_class(:jellyfin), do: "text-primary"
  def media_server_type_icon_class(_), do: "text-base-content/60"

  defp media_server_type_label(:jellyfin), do: "Jellyfin"

  defp media_server_type_label(type) when is_atom(type),
    do: Atom.to_string(type) |> String.capitalize()

  defp media_server_type_label(type), do: to_string(type)

  defp health_status_dot_class(:healthy), do: "bg-success animate-pulse"
  defp health_status_dot_class(:unhealthy), do: "bg-error"
  defp health_status_dot_class(:unknown), do: "bg-warning"
  defp health_status_dot_class(:disabled), do: "bg-base-content/30"

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

  # Card action buttons: two per row on phones, with a lone trailing button
  # stretching to fill, and today's compact right-aligned row from `sm` up.
  #
  # DaisyUI 5 .btn is 2.5rem and .btn-sm is 2rem, both under the 44px iOS and
  # 48px Android touch-target guidance. `min-h-11` (2.75rem) clamps the
  # component's own `height`; a Tailwind `h-*` utility would be competing with
  # DaisyUI's own cascade layer and is not reliable here.
  defp card_action_btn,
    do: "flex-1 basis-[45%] min-h-11 sm:flex-none sm:basis-auto sm:btn-sm sm:min-h-8"

  # Modal footer buttons: full-width stacked rows on phones, today's inline
  # row from `sm` up. Same 44px reasoning as card_action_btn/0.
  @doc false
  def modal_action_btn, do: "w-full min-h-11 sm:w-auto sm:min-h-8"

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
