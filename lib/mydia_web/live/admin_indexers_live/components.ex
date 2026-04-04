defmodule MydiaWeb.AdminIndexersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings

  @doc """
  Renders the Indexers tab content.
  Shows both configured indexers (Prowlarr/Jackett) and enabled library indexers.
  """
  attr :indexers, :list, required: true
  attr :indexer_health, :map, required: true
  attr :library_indexers, :list, required: true
  attr :library_indexer_stats, :map, required: true
  attr :cardigann_enabled, :boolean, required: true
  attr :recently_disabled_indexer, :any, default: nil
  attr :flaresolverr_available, :boolean, default: false

  def indexers_tab(assigns) do
    # Calculate total count of enabled indexers
    assigns =
      assign(
        assigns,
        :total_indexers,
        length(assigns.indexers) + length(assigns.library_indexers)
      )

    ~H"""
    <div class="p-4 sm:p-6 space-y-6">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="w-5 h-5 opacity-60" /> Indexers
          <span class="badge badge-ghost">{@total_indexers}</span>
        </h2>
        <div class="flex gap-2">
          <%!-- Add Indexer Dropdown --%>
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-sm btn-primary">
              <.icon name="hero-plus" class="w-4 h-4" /> Add Indexer
              <.icon name="hero-chevron-down" class="w-3 h-3" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow bg-base-200 rounded-box w-64"
            >
              <li>
                <button phx-click="new_indexer" class="flex items-start gap-3">
                  <.icon name="hero-server" class="w-5 h-5 mt-0.5 opacity-60" />
                  <div class="text-left">
                    <div class="font-medium">Connect to Prowlarr/Jackett</div>
                    <div class="text-xs text-base-content/60">
                      Use an existing indexer aggregator
                    </div>
                  </div>
                </button>
              </li>
              <%= if @cardigann_enabled do %>
                <li>
                  <button phx-click="show_indexer_library" class="flex items-start gap-3">
                    <.icon name="hero-book-open" class="w-5 h-5 mt-0.5 opacity-60" />
                    <div class="text-left">
                      <div class="font-medium">Browse Indexer Library</div>
                      <div class="text-xs text-base-content/60">
                        {@library_indexer_stats.total} indexers available
                      </div>
                    </div>
                  </button>
                </li>
              <% end %>
            </ul>
          </div>
        </div>
      </div>

      <%= if @indexers == [] and @library_indexers == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No indexers configured yet. Add a Prowlarr/Jackett connection or browse the indexer library to get started.
          </span>
        </div>
      <% else %>
        <%!-- Configured Indexers Section (Prowlarr/Jackett) --%>
        <%= if @indexers != [] do %>
          <div class="space-y-3">
            <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
              <.icon name="hero-server" class="w-4 h-4" /> Indexer Connections
              <span class="badge badge-ghost badge-sm">{length(@indexers)}</span>
            </h3>
            <div class="bg-base-200 rounded-box divide-y divide-base-300">
              <%= for indexer <- @indexers do %>
                <% health = Map.get(@indexer_health, indexer.id, %{status: :unknown}) %>
                <% is_runtime = Settings.runtime_config?(indexer) %>

                <div class="p-3 sm:p-4">
                  <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                    <div class="flex-1 min-w-0">
                      <div class="font-semibold flex items-center gap-2 flex-wrap">
                        {indexer.name}
                        <%= if is_runtime do %>
                          <span
                            class="badge badge-primary badge-xs tooltip"
                            data-tip="Configured via environment variables (read-only)"
                          >
                            <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                          </span>
                        <% end %>
                      </div>
                      <div class="text-xs opacity-60 mt-1 truncate">
                        <span class="font-mono">{indexer.base_url}</span>
                      </div>
                    </div>

                    <div class="flex flex-wrap items-center gap-2">
                      <span class="badge badge-sm badge-outline">
                        {format_indexer_type(indexer.type)}
                      </span>
                      <span class={[
                        "badge badge-sm",
                        if(indexer.enabled, do: "badge-success", else: "badge-ghost")
                      ]}>
                        {if indexer.enabled, do: "Enabled", else: "Disabled"}
                      </span>
                      <span class={"badge badge-sm #{health_status_badge_class(health.status)}"}>
                        <.icon name={health_status_icon(health.status)} class="w-3 h-3 mr-1" />
                        {health_status_label(health.status)}
                      </span>
                      <%= if health.status == :unhealthy and health[:error] do %>
                        <div class="tooltip tooltip-left" data-tip={health.error}>
                          <.icon name="hero-information-circle" class="w-4 h-4 text-error" />
                        </div>
                      <% end %>
                      <%= if health.status == :healthy and health[:details] && Map.get(health.details, :version) do %>
                        <div
                          class="tooltip tooltip-left"
                          data-tip={"Version: #{health.details.version}"}
                        >
                          <.icon name="hero-information-circle" class="w-4 h-4 text-success" />
                        </div>
                      <% end %>
                      <%= if health[:consecutive_failures] && health.consecutive_failures > 0 do %>
                        <div
                          class="tooltip tooltip-left"
                          data-tip={"#{health.consecutive_failures} consecutive failures"}
                        >
                          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
                        </div>
                      <% end %>

                      <div class="join ml-auto sm:ml-2">
                        <button
                          class="btn btn-sm btn-ghost join-item"
                          phx-click="test_indexer"
                          phx-value-id={indexer.id}
                          title="Test Connection"
                        >
                          <.icon name="hero-signal" class="w-4 h-4" />
                        </button>
                        <button
                          class="btn btn-sm btn-ghost join-item"
                          phx-click="edit_indexer"
                          phx-value-id={indexer.id}
                          title={if is_runtime, do: "Convert to database-managed", else: "Edit"}
                        >
                          <.icon name="hero-pencil" class="w-4 h-4" />
                        </button>
                        <%= if is_runtime do %>
                          <div
                            class="tooltip"
                            data-tip="Cannot delete runtime-configured indexers"
                          >
                            <button class="btn btn-sm btn-ghost join-item" disabled>
                              <.icon name="hero-trash" class="w-4 h-4 opacity-30" />
                            </button>
                          </div>
                        <% else %>
                          <button
                            class="btn btn-sm btn-ghost join-item text-error"
                            phx-click="delete_indexer"
                            phx-value-id={indexer.id}
                            data-confirm="Are you sure you want to delete this indexer?"
                            title="Delete"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
        <%!-- Library Indexers Section --%>
        <%= if @library_indexers != [] or @recently_disabled_indexer do %>
          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <h3 class="text-sm font-medium text-base-content/70 flex items-center gap-2">
                <.icon name="hero-book-open" class="w-4 h-4" /> Library Indexers
                <span class="badge badge-ghost badge-sm">{length(@library_indexers)}</span>
              </h3>
              <button
                phx-click="show_indexer_library"
                class="btn btn-xs btn-ghost text-primary"
                title="Browse and add more indexers from the library"
              >
                <.icon name="hero-plus" class="w-3 h-3" /> Add More
              </button>
            </div>
            <%!-- Undo Banner for Recently Disabled Indexer --%>
            <%= if @recently_disabled_indexer do %>
              <div class="alert alert-warning shadow-sm">
                <.icon name="hero-arrow-uturn-left" class="w-5 h-5" />
                <span>
                  <strong>{@recently_disabled_indexer.name}</strong> was disabled
                </span>
                <div class="flex gap-2">
                  <button class="btn btn-sm btn-ghost" phx-click="undo_disable_library_indexer">
                    Undo
                  </button>
                  <button
                    class="btn btn-sm btn-ghost btn-circle"
                    phx-click="dismiss_undo_banner"
                    title="Dismiss"
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              </div>
            <% end %>
            <div class="bg-base-200 rounded-box divide-y divide-base-300">
              <%= for indexer <- @library_indexers do %>
                <div class="p-3 sm:p-4">
                  <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                    <div class="flex-1 min-w-0">
                      <div class="font-semibold flex items-center gap-2 flex-wrap">
                        {indexer.name}
                        <span class={"badge badge-xs #{library_indexer_type_badge_class(indexer.type)}"}>
                          {indexer.type}
                        </span>
                        <%= if indexer.language do %>
                          <span class="badge badge-xs badge-ghost">{indexer.language}</span>
                        <% end %>
                      </div>
                      <%= if indexer.description do %>
                        <div class="text-xs opacity-60 mt-1 line-clamp-1">
                          {indexer.description}
                        </div>
                      <% end %>
                    </div>

                    <div class="flex flex-wrap items-center gap-2 sm:gap-3">
                      <%!-- Status badges --%>
                      <%= if indexer.health_status not in [nil, "unknown"] do %>
                        <span class={"badge badge-sm #{library_health_status_badge_class(indexer.health_status)}"}>
                          {library_health_status_label(indexer.health_status)}
                        </span>
                      <% end %>
                      <%= if needs_library_config?(indexer) do %>
                        <div class="tooltip" data-tip="This indexer requires configuration">
                          <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
                        </div>
                      <% end %>

                      <%!-- Divider --%>
                      <div class="hidden sm:block w-px h-5 bg-base-300"></div>

                      <%!-- Enable/Disable toggle --%>
                      <div
                        class="tooltip"
                        data-tip={if indexer.enabled, do: "Disable", else: "Enable"}
                      >
                        <input
                          type="checkbox"
                          class="toggle toggle-success toggle-sm"
                          checked={indexer.enabled}
                          phx-click="toggle_library_indexer"
                          phx-value-id={indexer.id}
                        />
                      </div>

                      <%!-- FlareSolverr toggle with label --%>
                      <%= if @flaresolverr_available do %>
                        <div class="flex items-center gap-1.5">
                          <div
                            class="tooltip tooltip-left"
                            data-tip={
                              if indexer.flaresolverr_required,
                                do: "Cloudflare bypass (recommended for this indexer)",
                                else: "Enable Cloudflare bypass via FlareSolverr"
                            }
                          >
                            <label class="flex items-center gap-1.5 cursor-pointer">
                              <.icon
                                name="hero-shield-check"
                                class={"w-4 h-4 #{if(indexer.flaresolverr_enabled, do: "text-warning", else: "text-base-content/30")}"}
                              />
                              <span class="text-xs text-base-content/60 hidden sm:inline">CF</span>
                              <input
                                type="checkbox"
                                class={[
                                  "toggle toggle-xs",
                                  if(indexer.flaresolverr_required,
                                    do: "toggle-warning",
                                    else: "toggle-info"
                                  )
                                ]}
                                checked={indexer.flaresolverr_enabled}
                                phx-click="toggle_library_flaresolverr"
                                phx-value-id={indexer.id}
                              />
                            </label>
                          </div>
                        </div>
                      <% end %>

                      <%!-- Configure button --%>
                      <button
                        class="btn btn-sm btn-ghost"
                        phx-click="configure_library_indexer"
                        phx-value-id={indexer.id}
                        title="Configure"
                      >
                        <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                      </button>

                      <%!-- Test button --%>
                      <button
                        class="btn btn-sm btn-ghost"
                        phx-click="test_library_indexer"
                        phx-value-id={indexer.id}
                        title="Test Connection"
                      >
                        <.icon name="hero-signal" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Helper functions for library indexer display
  defp library_indexer_type_badge_class("public"), do: "badge-success"
  defp library_indexer_type_badge_class("private"), do: "badge-error"
  defp library_indexer_type_badge_class("semi-private"), do: "badge-warning"
  defp library_indexer_type_badge_class(_), do: "badge-ghost"

  defp library_health_status_badge_class("healthy"), do: "badge-success"
  defp library_health_status_badge_class("degraded"), do: "badge-warning"
  defp library_health_status_badge_class("unhealthy"), do: "badge-error"
  defp library_health_status_badge_class(_), do: "badge-ghost"

  defp library_health_status_label("healthy"), do: "Healthy"
  defp library_health_status_label("degraded"), do: "Degraded"
  defp library_health_status_label("unhealthy"), do: "Unhealthy"
  defp library_health_status_label(_), do: "Unknown"

  defp needs_library_config?(%{type: "public"}), do: false

  defp needs_library_config?(%{type: type, config: nil})
       when type in ["private", "semi-private"],
       do: true

  defp needs_library_config?(%{type: type, config: config})
       when type in ["private", "semi-private"] and config == %{},
       do: true

  defp needs_library_config?(_), do: false

  defp health_status_badge_class(:healthy), do: "badge-success"
  defp health_status_badge_class(:unhealthy), do: "badge-error"
  defp health_status_badge_class(:unknown), do: "badge-ghost"

  defp health_status_icon(:healthy), do: "hero-check-circle"
  defp health_status_icon(:unhealthy), do: "hero-x-circle"
  defp health_status_icon(:unknown), do: "hero-question-mark-circle"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unknown), do: "Unknown"

  defp format_indexer_type(type) when is_atom(type) do
    type |> to_string() |> String.capitalize()
  end

  defp format_indexer_type(type), do: to_string(type)
end
