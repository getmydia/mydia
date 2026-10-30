defmodule MydiaWeb.AdminSystemLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  # ============================================================================
  # Tab Components
  # ============================================================================

  attr :system_info, :map, required: true
  attr :database_info, :map, required: true
  attr :library_paths_count, :integer, required: true
  attr :download_clients_count, :integer, required: true
  attr :indexers_count, :integer, required: true
  attr :stuck_upgrades, :integer, required: true

  def status_tab(assigns) do
    ~H"""
    <%!--
      Stuck upgrades. Only rendered when there is something wrong: a zero here
      is the normal state and would be pure noise on every visit.
      --%>
    <%= if @stuck_upgrades > 0 do %>
      <div id="stuck-upgrades-alert" class="alert alert-warning shadow-sm">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div class="flex-1">
          <div class="font-medium">
            {ngettext(
              "%{count} file is stuck mid-upgrade",
              "%{count} files are stuck mid-upgrade",
              @stuck_upgrades
            )}
          </div>
          <div class="text-sm opacity-80">
            {gettext(
              "Each one is holding its replacement and the copy it was meant to replace, so that disk space stays spoken for until the upgrade finishes. This happens when the finalize step never ran or failed after import. Look for failed %{worker} jobs.",
              worker: "UpgradeFinalize"
            )}
          </div>
        </div>
        <.link navigate={~p"/admin/jobs"} class="btn btn-sm">{gettext("View jobs")}</.link>
      </div>
    <% end %>

    <%!-- Top Row: System Info + Database --%>
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <%!-- System Information --%>
      <.admin_section id="status-system" title={gettext("System")} icon="hero-server">
        <div class="grid grid-cols-2 gap-2 sm:gap-4">
          <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
            <div class="stat-title text-xs sm:text-sm">{gettext("Version")}</div>
            <div class="stat-value text-base sm:text-xl">
              <.link
                navigate={~p"/changelog"}
                class="link link-hover max-sm:inline-flex max-sm:items-center max-sm:min-h-6"
              >
                {@system_info.app_version}
              </.link>
              <%= if @system_info.dev_mode do %>
                <span class="badge badge-warning badge-xs sm:badge-sm ml-1">
                  {gettext("dev")}
                </span>
              <% end %>
            </div>
            <div :if={@system_info.available_update} class="stat-desc mt-1">
              <a
                id="status-update-available"
                href={@system_info.available_update.url}
                target="_blank"
                rel="noopener noreferrer"
                class="badge badge-info badge-sm gap-1 hover:brightness-110"
              >
                <.icon name="hero-arrow-up-circle" class="size-3.5" />
                {gettext("%{version} available", version: @system_info.available_update.version)}
              </a>
            </div>
          </div>
          <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
            <div class="stat-title text-xs sm:text-sm">Elixir</div>
            <div class="stat-value text-base sm:text-xl">{@system_info.elixir_version}</div>
          </div>
          <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
            <div class="stat-title text-xs sm:text-sm">{gettext("Memory")}</div>
            <div class="stat-value text-base sm:text-xl">{@system_info.memory_used}</div>
          </div>
          <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
            <div class="stat-title text-xs sm:text-sm">{gettext("Uptime")}</div>
            <div class="stat-value text-base sm:text-xl">{@system_info.uptime}</div>
          </div>
        </div>
      </.admin_section>

      <%!-- Database Information --%>
      <.admin_section id="status-database" title={gettext("Database")} icon="hero-circle-stack">
        <:actions>
          <span class={"badge badge-sm sm:badge-md #{health_badge(@database_info.health)}"}>
            {if @database_info.health == :healthy,
              do: gettext("Healthy"),
              else: gettext("Unhealthy")}
          </span>
        </:actions>
        <div class="space-y-2 sm:space-y-3 bg-base-200 rounded-lg p-3 sm:p-5">
          <%= if @database_info.adapter == :postgres do %>
            <div class="flex justify-between items-center gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Adapter")}</span>
              <span class="badge badge-info badge-sm">PostgreSQL</span>
            </div>
            <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Host")}</span>
              <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate">
                {@database_info.hostname}:{@database_info.port}
              </code>
            </div>
            <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Database")}</span>
              <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate">
                {@database_info.database}
              </code>
            </div>
            <div class="flex justify-between items-center gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Size")}</span>
              <span class="font-medium text-sm">{@database_info.size}</span>
            </div>
          <% else %>
            <div class="flex justify-between items-center gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Adapter")}</span>
              <span class="badge badge-info badge-sm">SQLite</span>
            </div>
            <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Location")}</span>
              <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate max-w-full sm:max-w-[250px]">
                {@database_info.path}
              </code>
            </div>
            <div class="flex justify-between items-center gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Size")}</span>
              <span class="font-medium text-sm">{@database_info.size}</span>
            </div>
            <div class="flex justify-between items-center gap-2">
              <span class="text-base-content/70 text-sm">{gettext("Exists")}</span>
              <span class={[
                "badge badge-sm",
                if(@database_info.exists, do: "badge-success", else: "badge-error")
              ]}>
                {if @database_info.exists, do: gettext("Yes"), else: gettext("No")}
              </span>
            </div>
          <% end %>
        </div>
      </.admin_section>
    </div>

    <%!-- Bottom Row: Configuration Summary --%>
    <.admin_section
      id="status-configuration"
      title={gettext("Configuration")}
      icon="hero-adjustments-horizontal"
    >
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-folder" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Library Paths")}</div>
          <div class="stat-value text-xl">{@library_paths_count}</div>
          <div class="stat-desc">
            <%= if @library_paths_count == 0 do %>
              {gettext("No paths configured")}
            <% else %>
              {gettext("Configured")}
            <% end %>
          </div>
        </div>

        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-arrow-down-tray" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Download Clients")}</div>
          <div class="stat-value text-xl">{@download_clients_count}</div>
          <div class="stat-desc">
            <%= if @download_clients_count == 0 do %>
              {gettext("No clients configured")}
            <% else %>
              {gettext("Configured")}
            <% end %>
          </div>
        </div>

        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-magnifying-glass" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Indexers")}</div>
          <div class="stat-value text-xl">{@indexers_count}</div>
          <div class="stat-desc">
            <%= if @indexers_count == 0 do %>
              {gettext("No indexers configured")}
            <% else %>
              {gettext("Configured")}
            <% end %>
          </div>
        </div>
      </div>
    </.admin_section>
    """
  end

  defp health_badge(:healthy), do: "badge-success"
  defp health_badge(:unhealthy), do: "badge-error"
  defp health_badge(:unknown), do: "badge-warning"
  defp health_badge(_), do: "badge-ghost"
end
