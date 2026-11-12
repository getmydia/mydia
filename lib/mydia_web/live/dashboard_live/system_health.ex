defmodule MydiaWeb.DashboardLive.SystemHealth do
  @moduledoc """
  The home dashboard's system health widget: the rollups it renders and the
  timer that refreshes them every minute.

  The timer sends `:refresh_health` to the LiveView, which calls `load/1`
  again, or `cancel_refresh/1` once the widget is hidden.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, cancel_async: 2]

  alias Mydia.Downloads.ClientHealth
  alias Mydia.Health.Rollup
  alias Mydia.Indexers.CardigannSummary
  alias Mydia.Library

  @refresh_interval 60_000

  @doc """
  Assigns the health rollups and schedules the next refresh.

  Shared by the first load and the periodic refresh. Indexer health counts
  configured connections and enabled Cardigann library trackers together.
  """
  def load(socket) do
    client_status = ClientHealth.status_map()

    indexer_status =
      Map.merge(Mydia.Indexers.Health.status_map(), CardigannSummary.status_map())

    media_server_status =
      Mydia.MediaServer.Health.status_map(Mydia.Settings.list_media_server_configs())

    trash_summary = Library.trashed_summary()
    flaresolverr_enabled = Mydia.Indexers.FlareSolverr.enabled?()

    socket
    |> schedule_refresh()
    |> assign(:clients_rollup, Rollup.from_status_map(client_status))
    |> assign(:indexers_rollup, Rollup.from_status_map(indexer_status))
    |> assign(:media_servers_rollup, Rollup.from_status_map(media_server_status))
    |> assign(:cardigann_summary, CardigannSummary.build())
    |> assign(:trash_summary, trash_summary)
    |> assign(:flaresolverr_enabled, flaresolverr_enabled)
    |> start_async(:duplicate_count, fn ->
      plan = Mydia.Library.Prune.plan()
      length(plan.decisions)
    end)
    |> then(fn s ->
      if flaresolverr_enabled do
        s
        |> assign(:flaresolverr_status, :checking)
        |> start_async(:flaresolverr_status, fn ->
          Mydia.Indexers.FlareSolverr.status()
        end)
      else
        s
        |> cancel_async(:flaresolverr_status)
        |> assign(:flaresolverr_status, :disabled)
      end
    end)
  end

  @doc "Cancels the pending refresh, if any."
  def cancel_refresh(socket) do
    if timer = socket.assigns[:health_timer_ref] do
      Process.cancel_timer(timer)
    end

    assign(socket, :health_timer_ref, nil)
  end

  defp schedule_refresh(socket) do
    socket = cancel_refresh(socket)
    ref = Process.send_after(self(), :refresh_health, @refresh_interval)
    assign(socket, :health_timer_ref, ref)
  end
end
