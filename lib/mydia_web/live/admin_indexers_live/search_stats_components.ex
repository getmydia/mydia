defmodule MydiaWeb.AdminIndexersLive.SearchStatsComponents do
  @moduledoc """
  Per-indexer search stats on the Indexers page, read from
  `Mydia.Indexers.SearchStats`. Events live in `SearchStatsEvents`.
  """
  use MydiaWeb, :html

  alias Mydia.Indexers.SearchStats.Summary
  alias Phoenix.LiveView.JS

  @healthy_percent 95
  @degraded_percent 80

  attr :window, :atom, required: true

  def window_toggle(assigns) do
    ~H"""
    <div id="indexer-stats-window" class="join" role="group" aria-label={gettext("Stats window")}>
      <button
        :for={{window, label} <- [day: gettext("24h"), week: gettext("7d")]}
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
    <div id={"indexer-stats-#{@indexer_id}"} class="flex flex-row flex-wrap gap-2">
      <span :if={@summaries == []} class="text-xs text-base-content/70">
        {gettext("No searches yet")}
      </span>
      <button
        :for={{summary, percent} <- Enum.map(@summaries, &{&1, success_percent(&1)})}
        type="button"
        id={stats_id(@indexer_id, summary)}
        class="stats stats-horizontal bg-base-200 rounded-box max-w-full overflow-x-auto text-left transition-colors hover:bg-base-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        data-scroll-ok="a wide engine box scrolls sideways on phones"
        title={gettext("Show recent failures")}
        phx-click="show_search_failures"
        phx-value-id={@indexer_id}
      >
        <span
          :if={summary.engine}
          id={stats_id(@indexer_id, summary) <> "-engine"}
          class="stat py-1 px-3 place-content-center"
        >
          <span class="stat-title text-[11px]">{engine_label(summary.engine)}</span>
        </span>
        <span class="stat py-1 px-3">
          <span class="stat-title text-[11px]">{gettext("Success")}</span>
          <span
            id={stats_id(@indexer_id, summary) <> "-success"}
            class={["stat-value text-sm font-semibold", rate_class(percent)]}
          >
            {format_rate(percent)}
            <span class={suffix_class()}>
              {gettext("%{ok}/%{attempts}", ok: summary.successes, attempts: summary.attempts)}
            </span>
          </span>
        </span>
        <span class="stat py-1 px-3">
          <span class="stat-title text-[11px]">{gettext("Latency")}</span>
          <span class="stat-value text-sm font-semibold">
            {format_ms(summary.p50_ms)}
            <span class={suffix_class()}>
              {gettext("p90 %{p90}", p90: format_ms(summary.p90_ms))}
            </span>
          </span>
        </span>
        <span class="stat py-1 px-3">
          <span class="stat-title text-[11px]">{gettext("Results")}</span>
          <span class="stat-value text-sm font-semibold">
            {summary.avg_results || gettext("n/a")}
          </span>
        </span>
        <span class="stat py-1 px-3">
          <span class="stat-title text-[11px]">{gettext("Timeouts")}</span>
          <span
            id={stats_id(@indexer_id, summary) <> "-timeouts"}
            class={[
              "stat-value text-sm font-semibold",
              if(summary.timeouts > 0, do: "text-warning", else: "text-base-content/50")
            ]}
          >
            {summary.timeouts}
          </span>
        </span>
      </button>
    </div>
    """
  end

  attr :display, Mydia.TimeDisplay, required: true
  attr :failures, :map, default: nil

  def failures_modal(assigns) do
    ~H"""
    <.modal
      :if={@failures}
      id="indexer-failures"
      show
      on_cancel={JS.push("close_search_failures")}
    >
      <:title>{gettext("Recent failures: %{name}", name: @failures.name)}</:title>
      <p :if={@failures.rows == []} class="text-sm text-base-content/70">
        {gettext("No failures in the last 14 days.")}
      </p>
      <ul id="indexer-failures-list" class="flex flex-col gap-3 text-sm">
        <li
          :for={row <- @failures.rows}
          id={"indexer-failure-#{row.id}"}
          class="flex flex-col gap-0.5"
        >
          <span class="text-xs text-base-content/60">
            {format(row.inserted_at, :datetime, @display)} · {row.kind} · {row.outcome}
          </span>
          <span :if={row.error_message} class="break-words">{row.error_message}</span>
        </li>
      </ul>
    </.modal>
    """
  end

  defp stats_id(indexer_id, summary),
    do: "indexer-stats-#{indexer_id}-#{summary.engine || "none"}"

  # Integer math keeps the displayed percent and its color band in agreement.
  defp success_percent(%Summary{attempts: 0}), do: nil
  defp success_percent(%Summary{successes: ok, attempts: n}), do: div(ok * 100, n)

  defp rate_class(nil), do: "text-base-content/50"
  defp rate_class(pct) when pct >= @healthy_percent, do: "text-success"
  defp rate_class(pct) when pct >= @degraded_percent, do: "text-warning"
  defp rate_class(_pct), do: "text-error"

  # Muted sub-number on a value line; stays muted inside a colored success value.
  defp suffix_class, do: "text-xs font-normal text-base-content/60"

  defp engine_label("builtin"), do: gettext("Built-in")
  defp engine_label("prowlarr"), do: gettext("Prowlarr")
  defp engine_label(other), do: other

  defp format_rate(nil), do: gettext("n/a")
  defp format_rate(pct), do: "#{pct}%"

  defp format_ms(nil), do: gettext("n/a")
  defp format_ms(ms) when ms < 1_000, do: gettext("%{ms} ms", ms: ms)
  defp format_ms(ms), do: gettext("%{seconds} s", seconds: Float.round(ms / 1_000, 1))
end
