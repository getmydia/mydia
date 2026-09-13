defmodule MydiaWeb.DashboardLive.HealthComponents do
  @moduledoc """
  Components for the System Health dashboard widget.
  """
  use Phoenix.Component
  use MydiaWeb, :verified_routes

  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Health.Rollup
  alias MydiaWeb.AdminNav

  @doc "Renders the full System Health widget section."
  attr :clients_rollup, :map, required: true
  attr :indexers_rollup, :map, required: true
  attr :media_servers_rollup, :map, required: true
  attr :duplicates_state, :atom, required: true
  attr :duplicates_count, :integer, required: true
  attr :trash_summary, :map, required: true
  attr :flaresolverr_enabled, :boolean, default: false
  attr :flaresolverr_status, :atom, default: :checking

  def system_health_widget(assigns) do
    ~H"""
    <div id="system-health-widget" class="mb-6 md:mb-8">
      <div class="flex items-center gap-3 mb-3 md:mb-4">
        <h2 class="text-lg md:text-xl font-semibold truncate">System Health</h2>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-3 md:gap-4">
        <.health_tile
          :if={@clients_rollup.state != :none}
          id="health-tile-clients"
          nav_key={:clients}
          rollup={@clients_rollup}
        />

        <.health_tile
          :if={@indexers_rollup.state != :none}
          id="health-tile-indexers"
          nav_key={:indexers}
          rollup={@indexers_rollup}
          flaresolverr_enabled={@flaresolverr_enabled}
          flaresolverr_status={@flaresolverr_status}
        />

        <.health_tile
          :if={@media_servers_rollup.state != :none}
          id="health-tile-media-servers"
          nav_key={:media_servers}
          rollup={@media_servers_rollup}
        />

        <.duplicates_tile
          id="health-tile-duplicates"
          state={@duplicates_state}
          count={@duplicates_count}
        />

        <.trash_tile
          id="health-tile-trash"
          summary={@trash_summary}
        />
      </div>
    </div>
    """
  end

  @doc "Renders one service rollup tile (clients, indexers, media servers)."
  attr :id, :string, default: nil
  attr :nav_key, :atom, required: true
  attr :rollup, :map, required: true
  attr :flaresolverr_enabled, :boolean, default: false
  attr :flaresolverr_status, :atom, default: :checking

  def health_tile(assigns) do
    page = AdminNav.fetch!(assigns.nav_key)
    assigns = assign(assigns, :page, page)

    ~H"""
    <.link
      id={@id}
      navigate={@page.path}
      class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow border border-base-content/5"
    >
      <div class="card-body p-4 flex flex-col justify-between h-full">
        <div class="flex items-center justify-between gap-2">
          <span class="font-medium text-sm truncate">{@page.label}</span>
          <.icon name={@page.icon} class="w-4 h-4 text-base-content/60 shrink-0" />
        </div>

        <div class="mt-2">
          <div class="flex items-center gap-2">
            <span class={["badge badge-sm font-medium", state_badge_class(@rollup.state)]}>
              {Rollup.label(@rollup)}
            </span>
          </div>

          <div
            :if={@flaresolverr_enabled}
            id="flaresolverr-subline"
            class="text-xs text-base-content/60 mt-1.5 truncate"
          >
            {flaresolverr_text(@flaresolverr_status)}
          </div>
        </div>
      </div>
    </.link>
    """
  end

  attr :id, :string, default: nil
  attr :state, :atom, required: true
  attr :count, :integer, required: true

  defp duplicates_tile(assigns) do
    page = AdminNav.fetch!(:duplicates)
    assigns = assign(assigns, :page, page)

    ~H"""
    <.link
      id={@id}
      navigate={@page.path}
      class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow border border-base-content/5"
    >
      <div class="card-body p-4 flex flex-col justify-between h-full">
        <div class="flex items-center justify-between gap-2">
          <span class="font-medium text-sm truncate">{@page.label}</span>
          <.icon name={@page.icon} class="w-4 h-4 text-base-content/60 shrink-0" />
        </div>

        <div class="mt-2">
          <%= case @state do %>
            <% :checking -> %>
              <span class="badge badge-sm badge-ghost font-medium">Checking…</span>
            <% :unavailable -> %>
              <span class="badge badge-sm badge-ghost font-medium">Unavailable</span>
            <% :none -> %>
              <span class="badge badge-sm badge-success font-medium">None</span>
            <% _ -> %>
              <span class="badge badge-sm badge-warning font-medium">{@count} to review</span>
          <% end %>
        </div>
      </div>
    </.link>
    """
  end

  attr :id, :string, default: nil
  attr :summary, :map, required: true

  defp trash_tile(assigns) do
    page = AdminNav.fetch!(:trash)
    assigns = assign(assigns, :page, page)

    ~H"""
    <.link
      id={@id}
      navigate={@page.path}
      class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow border border-base-content/5"
    >
      <div class="card-body p-4 flex flex-col justify-between h-full">
        <div class="flex items-center justify-between gap-2">
          <span class="font-medium text-sm truncate">{@page.label}</span>
          <.icon name={@page.icon} class="w-4 h-4 text-base-content/60 shrink-0" />
        </div>

        <div class="mt-2">
          <span class="text-sm font-semibold text-base-content/80">
            <%= if @summary.count == 0 do %>
              Empty
            <% else %>
              {@summary.count} files · {format_bytes(@summary.bytes)}
            <% end %>
          </span>
        </div>
      </div>
    </.link>
    """
  end

  defp state_badge_class(:ok), do: "badge-success text-success-content"
  defp state_badge_class(:degraded), do: "badge-warning text-warning-content"
  defp state_badge_class(:down), do: "badge-error text-error-content"
  defp state_badge_class(_), do: "badge-ghost"

  defp flaresolverr_text(:checking), do: "FlareSolverr: checking…"
  defp flaresolverr_text(:healthy), do: "FlareSolverr: ok"
  defp flaresolverr_text(:unhealthy), do: "FlareSolverr: down"
  defp flaresolverr_text(:disabled), do: "FlareSolverr: disabled"
  defp flaresolverr_text(_), do: "FlareSolverr: unknown"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 ->
        "#{Float.round(bytes / 1_073_741_824, 1)} GB"

      bytes >= 1_048_576 ->
        "#{Float.round(bytes / 1_048_576, 1)} MB"

      bytes >= 1024 ->
        "#{Float.round(bytes / 1024, 1)} KB"

      true ->
        "#{bytes} B"
    end
  end
end
