defmodule MydiaWeb.AdminIndexersLive.SearchStatsEvents do
  @moduledoc """
  The per-indexer search stats on the Indexers page, as LiveView hooks so
  `AdminIndexersLive.Index` gains only a little wiring (the same pattern as
  `CardigannEngineEvents`).

  Stats load on a window change and through `refresh/1`, which the page calls
  whenever it reloads its library indexers (mount, Test, save, toggle). The
  cooldowns are also reread when the earliest shown one ends, so its badge
  goes away on time.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Mydia.Indexers.{RateLimiter, SearchStats}

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(
      search_stats_window: window(socket),
      search_failures: nil,
      # The page may have refreshed before attaching; keep what it read.
      cooldowns: Map.get(socket.assigns, :cooldowns, %{})
    )
    |> attach_hook(:search_stats_events, :handle_event, &handle_event/3)
    |> attach_hook(:search_stats_cooldowns, :handle_info, &handle_info/2)
  end

  @doc """
  Reloads the stats for the current window (24 hours before `attach/1` runs)
  and, beside them, which indexers are cooling down after HTTP 429.
  """
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    socket
    |> assign(search_stats: SearchStats.summary(window(socket)))
    |> refresh_cooldowns()
  end

  # Rereads the cooldowns and, while any runs, wakes when the earliest ends so
  # its badge goes away on time.
  defp refresh_cooldowns(socket) do
    cooldowns = cooldowns(socket)
    if ref = socket.assigns[:cooldown_timer], do: Process.cancel_timer(ref)

    assign(socket, cooldowns: cooldowns, cooldown_timer: schedule_expiry(socket, cooldowns))
  end

  defp schedule_expiry(socket, cooldowns) when map_size(cooldowns) > 0 do
    if connected?(socket), do: send_at_earliest(cooldowns)
  end

  defp schedule_expiry(_socket, _cooldowns), do: nil

  defp send_at_earliest(cooldowns) do
    earliest = cooldowns |> Map.values() |> Enum.min(DateTime)
    ms = max(DateTime.diff(earliest, DateTime.utc_now(), :millisecond), 0) + 100
    Process.send_after(self(), :search_stats_cooldown_ended, ms)
  end

  defp cooldowns(socket) do
    for %{id: id} <- all_indexers(socket),
        until = RateLimiter.cooldown_until(id),
        into: %{},
        do: {id, until}
  end

  defp handle_info(:search_stats_cooldown_ended, socket),
    do: {:halt, socket |> assign(cooldown_timer: nil) |> refresh_cooldowns()}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp all_indexers(socket),
    do: Map.get(socket.assigns, :indexers, []) ++ Map.get(socket.assigns, :library_indexers, [])

  defp window(socket), do: Map.get(socket.assigns, :search_stats_window, :day)

  defp handle_event("search_stats_window", %{"window" => window}, socket)
       when window in ["day", "week"] do
    {:halt, socket |> assign(search_stats_window: String.to_existing_atom(window)) |> refresh()}
  end

  defp handle_event("search_stats_window", _params, socket), do: {:halt, socket}

  defp handle_event("show_search_failures", %{"id" => id}, socket) do
    {:halt,
     assign(socket,
       search_failures: %{name: indexer_name(socket, id), rows: SearchStats.recent_failures(id)}
     )}
  end

  defp handle_event("close_search_failures", _params, socket),
    do: {:halt, assign(socket, search_failures: nil)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp indexer_name(socket, id) do
    socket
    |> all_indexers()
    |> Enum.find_value(gettext("Indexer"), fn indexer -> indexer.id == id && indexer.name end)
  end
end
