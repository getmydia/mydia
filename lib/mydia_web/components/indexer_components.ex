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
  Renders one chip per indexer, showing whether it is still searching, how many
  results it returned, or why it failed.

  `progress` is a map of `indexer_id => %IndexerProgress{}`. Pass `retry_event`
  to render a retry button on failed and timed-out indexers; the button sends
  that event with `phx-value-id` set to the indexer id.
  """
  attr :progress, :map, required: true
  attr :retry_event, :string, default: nil

  def indexer_search_status(assigns) do
    assigns = assign(assigns, :rows, sort_rows(assigns.progress))

    ~H"""
    <div :if={@rows != []} id="indexer-search-status" class="mb-4">
      <div class="flex flex-wrap items-center gap-2">
        <div
          :for={row <- @rows}
          id={"indexer-status-#{row.indexer_id}"}
          class={["badge badge-lg gap-2 py-3", status_class(row.status)]}
        >
          <span :if={row.status == :pending} class="loading loading-spinner loading-xs"></span>
          <.icon :if={row.status == :ok} name="hero-check-circle" class="w-4 h-4 shrink-0" />
          <.icon
            :if={row.status == :error}
            name="hero-exclamation-triangle"
            class="w-4 h-4 shrink-0"
          />
          <.icon :if={row.status == :timeout} name="hero-clock" class="w-4 h-4 shrink-0" />

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
        </div>
      </div>
    </div>
    """
  end

  # Sorted by name so chips keep a stable position as indexers settle out of
  # order. Sorting by status would make rows jump around mid-search.
  defp sort_rows(progress) do
    progress
    |> Map.values()
    |> Enum.sort_by(& &1.indexer)
  end

  defp status_class(:pending), do: "badge-ghost"
  defp status_class(:ok), do: "badge-success badge-outline"
  defp status_class(:error), do: "badge-error badge-outline"
  defp status_class(:timeout), do: "badge-warning badge-outline"

  defp status_label(%IndexerProgress{status: :pending}), do: "searching..."

  defp status_label(%IndexerProgress{status: :ok} = row),
    do: "#{row.result_count} results · #{row.duration_ms}ms"

  defp status_label(%IndexerProgress{status: :timeout}), do: "timed out"
  defp status_label(%IndexerProgress{status: :error} = row), do: row.error || "failed"
end
