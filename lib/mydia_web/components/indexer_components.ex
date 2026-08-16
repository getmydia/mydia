defmodule MydiaWeb.IndexerComponents do
  @moduledoc """
  Per-indexer progress display for manual search.

  Used by `MydiaWeb.SearchLive.Index` and the manual-search modal in
  `MydiaWeb.MediaLive.Show`. Imported explicitly by both rather than added to
  `html_helpers`: with two consumers it sits below the 3+ bar in CLAUDE.md's
  component organization rules.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Indexers.Structs.IndexerProgress

  @doc """
  Renders a collapsed summary of the search's progress — total results,
  completion count, and a failed count — with an expandable `<details>` list of
  one row per indexer.

  `progress` is a map of `indexer_id => %IndexerProgress{}`. Pass `retry_event`
  to render a retry button on failed and timed-out indexers; the button sends
  that event with `phx-value-id` set to the indexer id.
  """
  attr :progress, :map, required: true
  attr :retry_event, :string, default: nil

  def indexer_search_status(assigns) do
    rows = sort_rows(assigns.progress)

    total_results =
      rows
      |> Enum.filter(&(&1.status == :ok))
      |> Enum.reduce(0, &(&2 + (&1.result_count || 0)))

    done = Enum.count(rows, &(&1.status in [:ok, :error, :timeout]))
    total = length(rows)
    failed = Enum.count(rows, &(&1.status in [:error, :timeout]))

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:total_results, total_results)
      |> assign(:done, done)
      |> assign(:total, total)
      |> assign(:failed, failed)

    ~H"""
    <div :if={@rows != []} id="indexer-search-status" class="mb-4">
      <details class="collapse collapse-arrow bg-base-200/50 border border-base-300">
        <summary class="collapse-title text-sm font-medium flex items-center gap-2">
          <span>{@total_results} results · {@done}/{@total} indexers</span>
          <span :if={@failed > 0} class="badge badge-sm badge-error">{@failed} failed</span>
        </summary>
        <div class="collapse-content">
          <ul class="menu w-full">
            <li :for={row <- @rows} class="flex items-center gap-2">
              <span :if={row.status == :pending} class="loading loading-spinner loading-xs"></span>
              <.icon
                :if={row.status == :ok}
                name="hero-check-circle"
                class="w-4 h-4 shrink-0 text-success"
              />
              <.icon
                :if={row.status == :error}
                name="hero-exclamation-triangle"
                class="w-4 h-4 shrink-0 text-error"
              />
              <.icon
                :if={row.status == :timeout}
                name="hero-clock"
                class="w-4 h-4 shrink-0 text-warning"
              />

              <span class="font-medium">{row.indexer}</span>
              <span class="text-xs opacity-70">{status_label(row)}</span>

              <button
                :if={@retry_event && row.status in [:error, :timeout]}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click={@retry_event}
                phx-value-id={row.indexer_id}
              >
                Retry
              </button>
            </li>
          </ul>
        </div>
      </details>
    </div>
    """
  end

  # Sorted by name so rows keep a stable position as indexers settle out of
  # order. Sorting by status would make rows jump around mid-search.
  defp sort_rows(progress) do
    progress
    |> Map.values()
    |> Enum.sort_by(& &1.indexer)
  end

  defp status_label(%IndexerProgress{status: :pending}), do: "searching..."

  defp status_label(%IndexerProgress{status: :ok} = row),
    do: "#{row.result_count} results · #{row.duration_ms}ms"

  defp status_label(%IndexerProgress{status: :timeout}), do: "timed out"
  defp status_label(%IndexerProgress{status: :error} = row), do: row.error || "failed"
end
