defmodule MydiaWeb.IndexerComponents do
  @moduledoc """
  Per-indexer progress display for manual search, plus the paused-indexer formatting shared with the admin Indexers page.

  Used by `MydiaWeb.SearchLive.Index` and the manual-search modal in
  `MydiaWeb.MediaLive.Show`. Imported explicitly by both rather than added to
  `html_helpers`: with two consumers it sits below the 3+ bar in CLAUDE.md's
  component organization rules.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [button: 1, icon: 1]

  alias Mydia.Indexers.Structs.IndexerProgress

  @doc """
  Renders a collapsed summary of the search's progress — total results,
  completion count, and a failed count — with an expandable `<details>` list of
  one row per indexer.

  While any indexer is still outstanding the summary carries a spinner and a
  determinate progress bar, so an in-flight search is obvious without expanding
  the list. Both are replaced by a success check once every indexer settles.

  `progress` is a map of `indexer_id => %IndexerProgress{}`. Pass `retry_event`
  to render a retry button on failed and timed-out indexers; the button sends
  that event with `phx-value-id` set to the indexer id.

  Pass `retest_paused_event` to render a "Retest & search again" button on rows
  Prowlarr reported paused indexers for; it sends that event with `phx-value-id`
  set to the indexer id.
  """
  attr :progress, :map, required: true
  attr :retry_event, :string, default: nil
  attr :retest_paused_event, :string, default: nil

  def indexer_search_status(assigns) do
    rows = sort_rows(assigns.progress)

    total_results =
      rows
      |> Enum.filter(&(&1.status == :ok))
      |> Enum.reduce(0, &(&2 + (&1.result_count || 0)))

    done = Enum.count(rows, &(&1.status in [:ok, :error, :timeout]))
    total = length(rows)
    failed = Enum.count(rows, &(&1.status in [:error, :timeout]))
    paused = rows |> Enum.flat_map(& &1.paused) |> length()

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:total_results, total_results)
      |> assign(:done, done)
      |> assign(:total, total)
      |> assign(:failed, failed)
      |> assign(:paused, paused)
      # Derived rather than passed in: a row is :pending until it settles, and
      # a retry puts a settled row back to :pending, so this tracks a retry's
      # in-flight window too.
      |> assign(:searching, done < total)

    ~H"""
    <div :if={@rows != []} id="indexer-search-status" class="mb-4" aria-busy={to_string(@searching)}>
      <details class="collapse collapse-arrow bg-base-200/50 border border-base-300">
        <summary class="collapse-title text-sm font-medium flex flex-wrap items-center gap-x-2 gap-y-1">
          <span
            :if={@searching}
            class="loading loading-spinner loading-xs text-primary shrink-0"
            aria-hidden="true"
          ></span>
          <.icon
            :if={!@searching}
            name="hero-check-circle"
            class="w-4 h-4 shrink-0 text-success"
          />
          <span :if={@searching} class="sr-only">Searching indexers</span>
          <span>{@total_results} results · {@done}/{@total} indexers</span>
          <span :if={@failed > 0} class="badge badge-sm badge-error">{@failed} failed</span>
          <span
            :if={@paused > 0}
            id="indexer-search-paused-count"
            class="badge badge-sm badge-warning"
          >
            {@paused} paused
          </span>
          <progress
            :if={@searching}
            class="progress progress-primary w-full h-1"
            value={@done}
            max={@total}
          ></progress>
        </summary>
        <div class="collapse-content">
          <ul class="menu w-full">
            <li
              :for={row <- @rows}
              id={"indexer-status-#{row.indexer_id}"}
              class="flex flex-wrap items-center gap-2"
            >
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

              <.button
                :if={@retry_event && row.status in [:error, :timeout]}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click={@retry_event}
                phx-value-id={row.indexer_id}
              >
                Retry
              </.button>

              <div
                :if={row.paused != []}
                id={"indexer-paused-#{row.indexer_id}"}
                class="basis-full flex flex-wrap items-center gap-2 pl-6 text-xs text-warning"
              >
                <.icon name="hero-pause-circle" class="w-4 h-4 shrink-0" />
                <span>Skipped by Prowlarr (paused after failures): {paused_list(row.paused)}</span>
                <.button
                  :if={@retest_paused_event}
                  type="button"
                  id={"indexer-retest-paused-#{row.indexer_id}"}
                  class="btn btn-ghost btn-xs"
                  phx-click={@retest_paused_event}
                  phx-value-id={row.indexer_id}
                >
                  Retest &amp; search again
                </.button>
              </div>
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

  @doc ~S(Time left on a Prowlarr pause, coarsest unit: "<1m", "12m", "3h", "1d".)
  def paused_remaining(%DateTime{} = till, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(till, now, :second)

    cond do
      seconds < 60 -> "<1m"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  @doc "\"Amber Tracker (12m left), Birch Tracker (3h left)\""
  def paused_list(paused) do
    Enum.map_join(paused, ", ", &"#{&1.name} (#{paused_remaining(&1.disabled_till)} left)")
  end

  def paused_heading(1), do: "1 indexer paused by Prowlarr"
  def paused_heading(count), do: "#{count} indexers paused by Prowlarr"

  @doc """
  Flash kind and text for the result of
  `Mydia.Indexers.retest_paused_prowlarr_indexers/1`.
  """
  def retest_flash({:ok, %{outcomes: []}}), do: {:info, "No paused indexers to retest"}

  def retest_flash({:ok, %{outcomes: outcomes}}) do
    kind = if Enum.all?(outcomes, &match?({_, :ok}, &1)), do: :info, else: :error
    {kind, Enum.map_join(outcomes, ". ", &retest_outcome_text/1)}
  end

  def retest_flash({:error, reason}), do: {:error, "Retest failed: #{reason}"}

  defp retest_outcome_text({indexer, :ok}), do: "#{indexer.name} recovered"

  defp retest_outcome_text({indexer, {:error, message}}),
    do: "#{indexer.name} still failing: #{message}"
end
