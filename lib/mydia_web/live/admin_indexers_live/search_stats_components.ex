defmodule MydiaWeb.AdminIndexersLive.SearchStatsComponents do
  @moduledoc """
  Per-indexer search stats on the Indexers page, read from
  `Mydia.Indexers.SearchStats`. Events live in `SearchStatsEvents`.
  """
  use MydiaWeb, :html

  alias Mydia.Indexers.SearchStats.Summary
  alias Phoenix.LiveView.JS

  attr :window, :atom, required: true

  def window_toggle(assigns) do
    ~H"""
    <div id="indexer-stats-window" class="join" role="group" aria-label="Stats window">
      <button
        :for={{window, label} <- [day: "24h", week: "7d"]}
        type="button"
        id={"indexer-stats-window-#{window}"}
        class={["btn btn-xs join-item", @window == window && "btn-active"]}
        aria-pressed={to_string(@window == window)}
        phx-click="search_stats_window"
        phx-value-window={window}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :indexer_id, :string, required: true
  attr :summaries, :list, default: []

  def stats_strip(assigns) do
    ~H"""
    <div
      id={"indexer-stats-#{@indexer_id}"}
      class="flex flex-col gap-1 text-xs text-base-content/70"
    >
      <span :if={@summaries == []}>No searches yet</span>
      <button
        :for={summary <- @summaries}
        type="button"
        id={"indexer-stats-#{@indexer_id}-#{summary.engine || "none"}"}
        class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded text-left transition-colors hover:text-base-content focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        title="Show recent failures"
        aria-label="Recent failures for this indexer"
        phx-click="show_search_failures"
        phx-value-id={@indexer_id}
      >
        <span :if={summary.engine} class="badge badge-xs badge-ghost">
          {engine_label(summary.engine)}
        </span>
        <span>{format_rate(Summary.success_rate(summary))} ok of {summary.attempts}</span>
        <span :if={summary.timeouts > 0} class="text-warning">{summary.timeouts} timed out</span>
        <span>p50 {format_ms(summary.p50_ms)} / p90 {format_ms(summary.p90_ms)}</span>
        <span :if={summary.avg_results}>{summary.avg_results} results avg</span>
      </button>
    </div>
    """
  end

  attr :failures, :map, default: nil

  def failures_modal(assigns) do
    ~H"""
    <.modal
      :if={@failures}
      id="indexer-failures"
      show
      on_cancel={JS.push("close_search_failures")}
    >
      <:title>Recent failures: {@failures.name}</:title>
      <p :if={@failures.rows == []} class="text-sm text-base-content/70">
        No failures in the last 14 days.
      </p>
      <ul id="indexer-failures-list" class="flex flex-col gap-3 text-sm">
        <li
          :for={row <- @failures.rows}
          id={"indexer-failure-#{row.id}"}
          class="flex flex-col gap-0.5"
        >
          <span class="text-xs text-base-content/60">
            {format_time(row.inserted_at)} · {row.kind} · {row.outcome}
          </span>
          <span :if={row.error_message} class="break-words">{row.error_message}</span>
        </li>
      </ul>
    </.modal>
    """
  end

  defp engine_label("builtin"), do: "Built-in engine"
  defp engine_label("prowlarr"), do: "Prowlarr engine"
  defp engine_label(other), do: other

  defp format_rate(nil), do: "n/a"
  defp format_rate(rate), do: "#{round(rate * 100)}%"

  defp format_ms(nil), do: "n/a"
  defp format_ms(ms) when ms < 1_000, do: "#{ms} ms"
  defp format_ms(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  defp format_time(datetime), do: Calendar.strftime(datetime, "%b %-d, %H:%M UTC")
end
