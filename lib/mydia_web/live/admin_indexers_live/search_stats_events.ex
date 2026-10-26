defmodule MydiaWeb.AdminIndexersLive.SearchStatsEvents do
  @moduledoc """
  The per-indexer search stats on the Indexers page, as LiveView hooks so
  `AdminIndexersLive.Index` gains only a little wiring (the same pattern as
  `CardigannEngineEvents`).

  Stats load on a window change and through `refresh/1`, which the page calls
  whenever it reloads its library indexers (mount, Test, save, toggle).
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Mydia.Indexers.SearchStats

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(search_stats_window: window(socket), search_failures: nil)
    |> attach_hook(:search_stats_events, :handle_event, &handle_event/3)
  end

  @doc "Reloads the stats for the current window (24 hours before `attach/1` runs)."
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket), do: assign(socket, search_stats: SearchStats.summary(window(socket)))

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
    (Map.get(socket.assigns, :indexers, []) ++ Map.get(socket.assigns, :library_indexers, []))
    |> Enum.find_value(gettext("Indexer"), fn indexer -> indexer.id == id && indexer.name end)
  end
end
