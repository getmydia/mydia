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
    <div class="space-y-6 sm:space-y-8 p-4 sm:p-6">
      <%!--
      Stuck upgrades. Only rendered when there is something wrong: a zero here
      is the normal state and would be pure noise on every visit.
      --%>
      <%= if @stuck_upgrades > 0 do %>
        <div id="stuck-upgrades-alert" class="alert alert-warning shadow-sm">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <div class="flex-1">
            <div class="font-medium">
              {@stuck_upgrades} {if @stuck_upgrades == 1,
                do: "file is",
                else: "files are"} stuck mid-upgrade
            </div>
            <div class="text-sm opacity-80">
              Each one is holding its replacement and the copy it was meant to replace, so that
              disk space stays spoken for until the upgrade finishes. This happens when the
              finalize step never ran or failed after import. Look for failed
              <span class="font-mono">UpgradeFinalize</span>
              jobs.
            </div>
          </div>
          <.link navigate={~p"/admin/jobs"} class="btn btn-sm">View jobs</.link>
        </div>
      <% end %>

      <%!-- Top Row: System Info + Database --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 sm:gap-8">
        <%!-- System Information --%>
        <div>
          <h3 class="text-lg font-semibold flex items-center gap-2 mb-3 sm:mb-4">
            <.icon name="hero-server" class="w-5 h-5 text-primary" /> System
          </h3>
          <div class="grid grid-cols-2 gap-2 sm:gap-4">
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Version</div>
              <div class="stat-value text-base sm:text-xl">
                <.link navigate={~p"/changelog"} class="link link-hover">
                  {@system_info.app_version}
                </.link>
                <%= if @system_info.dev_mode do %>
                  <span class="badge badge-warning badge-xs sm:badge-sm ml-1">dev</span>
                <% end %>
              </div>
            </div>
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Elixir</div>
              <div class="stat-value text-base sm:text-xl">{@system_info.elixir_version}</div>
            </div>
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Memory</div>
              <div class="stat-value text-base sm:text-xl">{@system_info.memory_used}</div>
            </div>
            <div class="stat p-3 sm:p-4 bg-base-200 rounded-lg">
              <div class="stat-title text-xs sm:text-sm">Uptime</div>
              <div class="stat-value text-base sm:text-xl">{@system_info.uptime}</div>
            </div>
          </div>
        </div>

        <%!-- Database Information --%>
        <div>
          <h3 class="text-lg font-semibold flex items-center gap-2 mb-3 sm:mb-4 flex-wrap">
            <.icon name="hero-circle-stack" class="w-5 h-5 text-primary" /> Database
            <span class={"badge badge-sm sm:badge-md #{health_badge(@database_info.health)}"}>
              {if @database_info.health == :healthy, do: "Healthy", else: "Unhealthy"}
            </span>
          </h3>
          <div class="space-y-2 sm:space-y-3 bg-base-200 rounded-lg p-3 sm:p-5">
            <%= if @database_info.adapter == :postgres do %>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Adapter</span>
                <span class="badge badge-info badge-sm">PostgreSQL</span>
              </div>
              <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
                <span class="text-base-content/70 text-sm">Host</span>
                <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate">
                  {@database_info.hostname}:{@database_info.port}
                </code>
              </div>
              <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
                <span class="text-base-content/70 text-sm">Database</span>
                <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate">
                  {@database_info.database}
                </code>
              </div>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Size</span>
                <span class="font-medium text-sm">{@database_info.size}</span>
              </div>
            <% else %>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Adapter</span>
                <span class="badge badge-info badge-sm">SQLite</span>
              </div>
              <div class="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-1 sm:gap-2">
                <span class="text-base-content/70 text-sm">Location</span>
                <code class="text-xs sm:text-sm bg-base-300 px-2 py-1 rounded truncate max-w-full sm:max-w-[250px]">
                  {@database_info.path}
                </code>
              </div>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Size</span>
                <span class="font-medium text-sm">{@database_info.size}</span>
              </div>
              <div class="flex justify-between items-center gap-2">
                <span class="text-base-content/70 text-sm">Exists</span>
                <span class={[
                  "badge badge-sm",
                  if(@database_info.exists, do: "badge-success", else: "badge-error")
                ]}>
                  {if @database_info.exists, do: "Yes", else: "No"}
                </span>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <div class="divider"></div>

      <%!-- Bottom Row: Configuration Summary --%>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-6 sm:gap-8">
        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-folder" class="w-8 h-8" />
          </div>
          <div class="stat-title">Library Paths</div>
          <div class="stat-value text-xl">{@library_paths_count}</div>
          <div class="stat-desc">
            <%= if @library_paths_count == 0 do %>
              No paths configured
            <% else %>
              Configured
            <% end %>
          </div>
        </div>

        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-arrow-down-tray" class="w-8 h-8" />
          </div>
          <div class="stat-title">Download Clients</div>
          <div class="stat-value text-xl">{@download_clients_count}</div>
          <div class="stat-desc">
            <%= if @download_clients_count == 0 do %>
              No clients configured
            <% else %>
              Configured
            <% end %>
          </div>
        </div>

        <div class="stat p-4 bg-base-200 rounded-lg">
          <div class="stat-figure text-primary">
            <.icon name="hero-magnifying-glass" class="w-8 h-8" />
          </div>
          <div class="stat-title">Indexers</div>
          <div class="stat-value text-xl">{@indexers_count}</div>
          <div class="stat-desc">
            <%= if @indexers_count == 0 do %>
              No indexers configured
            <% else %>
              Configured
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp health_badge(:healthy), do: "badge-success"
  defp health_badge(:unhealthy), do: "badge-error"
  defp health_badge(:unknown), do: "badge-warning"
  defp health_badge(_), do: "badge-ghost"
end
