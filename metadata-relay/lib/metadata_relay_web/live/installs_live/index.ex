defmodule MetadataRelayWeb.InstallsLive.Index do
  @moduledoc """
  Maintainer dashboard: distinct Mydia installs per week, from their update
  checks, and how the latest week splits by version, architecture and
  database. See `MetadataRelay.UpdateCheck`.
  """

  use Phoenix.LiveView

  alias MetadataRelay.UpdateCheck

  @impl true
  def mount(_params, _session, socket) do
    weeks = UpdateCheck.weekly_counts(12)
    latest = List.first(weeks)

    {:ok,
     socket
     |> assign(:page_title, "Installs")
     |> assign(:weeks, weeks)
     |> assign(:latest, latest)
     |> assign(:current_week, UpdateCheck.week_of(Date.utc_today()))
     |> assign(:breakdowns, breakdowns(latest))}
  end

  defp breakdowns(nil), do: []

  defp breakdowns(%{week: week}) do
    [
      {"Version", UpdateCheck.breakdown(week, :version)},
      {"Architecture", UpdateCheck.breakdown(week, :arch)},
      {"Database", UpdateCheck.breakdown(week, :db)}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MetadataRelayWeb.Layouts.app flash={@flash}>
      <section id="installs-dashboard" class="space-y-6">
        <header class="space-y-2">
          <div class="badge badge-primary badge-lg">Maintainer dashboard</div>
          <h1 class="text-4xl font-semibold tracking-tight">Installs</h1>
          <p class="text-base leading-7 text-base-content/70">
            Distinct Mydia installs that checked for updates, per ISO week. An install
            checks at boot and weekly, so a week is complete once it has ended.
          </p>
        </header>

        <p :if={@weeks == []} id="installs-empty" class="text-sm text-base-content/60">
          No install has checked for updates yet.
        </p>

        <div :if={@weeks != []} class="grid gap-6 lg:grid-cols-2">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-4">
              <h2 class="card-title text-lg">Per week</h2>
              <table id="installs-weeks" class="table">
                <thead>
                  <tr>
                    <th>Week of</th>
                    <th class="text-right">Installs</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @weeks} id={"installs-week-#{row.week}"}>
                    <td>
                      {Date.to_iso8601(row.week)}
                      <span :if={row.week == @current_week} class="badge badge-ghost badge-sm ml-2">
                        in progress
                      </span>
                    </td>
                    <td class="text-right font-mono">{row.installs}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>

          <section
            :for={{title, rows} <- @breakdowns}
            id={"installs-by-#{String.downcase(title)}"}
            class="card border border-base-300 bg-base-100 shadow-sm"
          >
            <div class="card-body gap-4">
              <h2 class="card-title text-lg">
                {title}
                <span class="text-sm font-normal text-base-content/60">
                  week of {Date.to_iso8601(@latest.week)}
                </span>
              </h2>
              <table class="table">
                <tbody>
                  <tr :for={{value, count} <- rows}>
                    <td class="font-mono">{value}</td>
                    <td class="text-right font-mono">{count}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </section>
    </MetadataRelayWeb.Layouts.app>
    """
  end
end
