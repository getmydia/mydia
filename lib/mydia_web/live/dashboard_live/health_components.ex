defmodule MydiaWeb.DashboardLive.HealthComponents do
  @moduledoc """
  Components for the System Health dashboard widget.
  """
  use Phoenix.Component
  use MydiaWeb, :verified_routes
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Indexers.CardigannSummary
  alias MydiaWeb.AdminNav
  alias MydiaWeb.StatusLabels

  @doc """
  The fatal health alerts card at the top of the home dashboard: every alert
  with its detail, how long it has lasted and a link to the page that fixes
  it. Renders nothing for an empty list. Admins only; `@health_alerts` is
  empty for everyone else.
  """
  attr :alerts, :list, required: true, doc: "`Mydia.Health.Alert` structs"
  attr :now, :any, default: nil, doc: "the time durations are measured to (default: now)"

  def fatal_alerts_card(%{alerts: []} = assigns), do: ~H""

  def fatal_alerts_card(assigns) do
    assigns = assign(assigns, :now, assigns.now || DateTime.utc_now())

    ~H"""
    <section
      id="home-health-alerts"
      class="card bg-base-100 border border-error/40 shadow-sm mb-6 md:mb-8"
      aria-labelledby="home-health-alerts-title"
    >
      <div class="card-body gap-3 p-4 md:p-6">
        <h2
          id="home-health-alerts-title"
          class="flex items-center gap-2 text-lg font-semibold text-error"
        >
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          {ngettext(
            "%{count} problem is stopping Mydia from working",
            "%{count} problems are stopping Mydia from working",
            length(@alerts)
          )}
        </h2>
        <ul class="divide-y divide-base-content/10">
          <li
            :for={{alert, index} <- Enum.with_index(@alerts)}
            id={"home-health-alert-#{index}"}
            class="flex flex-col sm:flex-row sm:items-center gap-3 py-3 first:pt-0 last:pb-0"
          >
            <div class="flex-1 min-w-0">
              <p class="font-medium">
                {MydiaWeb.HealthAlertText.title(alert)}
                <span class="text-sm font-normal text-base-content/60">
                  · {MydiaWeb.HealthAlertText.duration(alert, @now)}
                </span>
              </p>
              <p :if={alert.detail} class="text-sm text-base-content/70 break-words">
                {alert.detail}
              </p>
            </div>
            <.link
              navigate={alert.fix_path}
              class="btn btn-sm btn-error btn-outline self-start sm:self-center shrink-0"
            >
              {gettext("Fix")} <.icon name="hero-arrow-right" class="w-4 h-4" />
            </.link>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  @doc "Renders the full System Health widget section."
  attr :clients_rollup, :map, required: true
  attr :indexers_rollup, :map, required: true
  attr :media_servers_rollup, :map, required: true
  attr :duplicates_state, :atom, required: true
  attr :duplicates_count, :integer, required: true
  attr :trash_summary, :map, required: true
  attr :flaresolverr_enabled, :boolean, default: false
  attr :flaresolverr_status, :atom, default: :checking
  attr :cardigann_summary, CardigannSummary, default: nil

  def system_health_widget(assigns) do
    ~H"""
    <div id="system-health-widget" class="mb-6 md:mb-8">
      <div class="flex items-center gap-3 mb-3 md:mb-4">
        <h2 class="text-lg md:text-xl font-semibold truncate">
          {gettext("System Health")}
        </h2>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-3 md:gap-4">
        <.health_tile
          :if={@clients_rollup.state != :none}
          id="health-tile-clients"
          nav_key={:clients}
          rollup={@clients_rollup}
        />

        <%!-- Always shown, unlike the other service tiles: with nothing set up
             it is the shortcut to the Indexers page. --%>
        <.health_tile
          id="health-tile-indexers"
          nav_key={:indexers}
          rollup={@indexers_rollup}
          empty_label={gettext("Not set up")}
          cardigann={@cardigann_summary}
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

  attr :empty_label, :string,
    default: nil,
    doc: "badge text when the rollup has nothing to count"

  attr :cardigann, CardigannSummary, default: nil

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
          <span class="font-medium text-sm truncate">{AdminNav.page_label(@page)}</span>
          <.icon name={@page.icon} class="w-4 h-4 text-base-content/60 shrink-0" />
        </div>

        <div class="mt-2">
          <div class="flex items-center gap-2">
            <span class={["badge badge-sm font-medium", state_badge_class(@rollup.state)]}>
              {if @rollup.state == :none, do: @empty_label, else: StatusLabels.rollup(@rollup)}
            </span>
          </div>

          <div
            :if={@cardigann && @cardigann.installed > 0}
            id="cardigann-engine-subline"
            title={StatusLabels.cardigann(@cardigann)}
            class="text-xs text-base-content/60 mt-1.5 truncate"
          >
            {StatusLabels.cardigann(@cardigann)}
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
          <span class="font-medium text-sm truncate">{AdminNav.page_label(@page)}</span>
          <.icon name={@page.icon} class="w-4 h-4 text-base-content/60 shrink-0" />
        </div>

        <div class="mt-2">
          <%= case @state do %>
            <% :checking -> %>
              <span class="badge badge-sm badge-ghost font-medium">
                {gettext("Checking…")}
              </span>
            <% :unavailable -> %>
              <span class="badge badge-sm badge-ghost font-medium">{gettext("Unavailable")}</span>
            <% :none -> %>
              <span class="badge badge-sm badge-success font-medium">{gettext("None")}</span>
            <% _ -> %>
              <span class="badge badge-sm badge-warning font-medium">
                {ngettext("%{count} to review", "%{count} to review", @count)}
              </span>
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
          <span class="font-medium text-sm truncate">{AdminNav.page_label(@page)}</span>
          <.icon name={@page.icon} class="w-4 h-4 text-base-content/60 shrink-0" />
        </div>

        <div class="mt-2">
          <span class="text-sm font-semibold text-base-content/80">
            <%= if @summary.count == 0 do %>
              {gettext("Empty")}
            <% else %>
              {ngettext(
                "%{count} file · %{size}",
                "%{count} files · %{size}",
                @summary.count,
                size: format_bytes(@summary.bytes)
              )}
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

  defp flaresolverr_text(:checking), do: gettext("FlareSolverr: checking…")
  defp flaresolverr_text(:healthy), do: gettext("FlareSolverr: ok")
  defp flaresolverr_text(:unhealthy), do: gettext("FlareSolverr: down")
  defp flaresolverr_text(:disabled), do: gettext("FlareSolverr: disabled")
  defp flaresolverr_text(_), do: gettext("FlareSolverr: unknown")

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
