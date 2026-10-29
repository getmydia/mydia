defmodule MydiaWeb.IndexerComponents do
  @moduledoc """
  Per-indexer progress display for manual search, plus the paused-indexer formatting shared with the admin Indexers page.

  Used by `MydiaWeb.SearchLive.Index` and the manual-search modal in
  `MydiaWeb.MediaLive.Show`. Imported explicitly by both rather than added to
  `html_helpers`: with two consumers it sits below the 3+ bar in CLAUDE.md's
  component organization rules.
  """

  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [button: 1, icon: 1]

  alias Mydia.Indexers.CardigannSummary
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

  Pass `cardigann` (a `%Mydia.Indexers.CardigannSummary{}`) to show which
  Cardigann engine runs the library trackers and how many are enabled.
  """
  attr :progress, :map, required: true
  attr :retry_event, :string, default: nil
  attr :retest_paused_event, :string, default: nil
  attr :cardigann, CardigannSummary, default: nil

  def indexer_search_status(assigns) do
    now = DateTime.utc_now()

    rows =
      assigns.progress
      |> sort_rows()
      |> Enum.map(&%{&1 | paused: active_paused(&1.paused, now)})

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
          <span :if={@searching} class="sr-only">{gettext("Searching indexers")}</span>
          <span>
            {ngettext(
              "%{count} result · %{done}/%{total} indexers",
              "%{count} results · %{done}/%{total} indexers",
              @total_results,
              done: @done,
              total: @total
            )}
          </span>
          <span
            :if={@cardigann && @cardigann.installed > 0}
            id="indexer-search-cardigann"
            class="badge badge-sm badge-ghost"
          >
            {MydiaWeb.StatusLabels.cardigann(@cardigann)}
          </span>
          <span :if={@failed > 0} class="badge badge-sm badge-error">
            {ngettext("%{count} failed", "%{count} failed", @failed)}
          </span>
          <span
            :if={@paused > 0}
            id="indexer-search-paused-count"
            class="badge badge-sm badge-warning"
          >
            {ngettext("%{count} paused", "%{count} paused", @paused)}
          </span>
          <progress
            :if={@searching}
            class="progress progress-primary w-full h-1"
            value={@done}
            max={@total}
          ></progress>
        </summary>
        <div class="collapse-content">
          <%!-- A plain list rather than daisyUI's menu: menu items lay their
               children out as a column, which stacked icon, name and status
               on top of each other on narrow screens. --%>
          <ul class="w-full divide-y divide-base-300 text-sm">
            <li
              :for={row <- @rows}
              id={"indexer-status-#{row.indexer_id}"}
              class="flex flex-wrap items-center gap-x-2 gap-y-1 py-2"
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

              <span class="min-w-0 flex-1 truncate font-medium">{row.indexer}</span>
              <span class="min-w-0 break-words text-right text-xs opacity-70">{status_label(row)}</span>

              <.button
                :if={@retry_event && row.status in [:error, :timeout]}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click={@retry_event}
                phx-value-id={row.indexer_id}
              >
                {gettext("Retry")}
              </.button>

              <div
                :if={row.paused != []}
                id={"indexer-paused-#{row.indexer_id}"}
                class="basis-full flex flex-wrap items-center gap-2 pl-6 text-xs text-warning"
              >
                <.icon name="hero-pause-circle" class="w-4 h-4 shrink-0" />
                <span>
                  {gettext("Skipped by Prowlarr (paused after failures): %{indexers}",
                    indexers: paused_list(row.paused)
                  )}
                </span>
                <.button
                  :if={@retest_paused_event}
                  type="button"
                  id={"indexer-retest-paused-#{row.indexer_id}"}
                  class="btn btn-ghost btn-xs"
                  phx-click={@retest_paused_event}
                  phx-value-id={row.indexer_id}
                >
                  {gettext("Retest & search again")}
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

  defp status_label(%IndexerProgress{status: :pending}), do: gettext("searching...")

  defp status_label(%IndexerProgress{status: :ok} = row),
    do:
      ngettext(
        "%{count} result · %{duration}ms",
        "%{count} results · %{duration}ms",
        row.result_count || 0,
        duration: row.duration_ms
      )

  defp status_label(%IndexerProgress{status: :timeout}), do: gettext("timed out")
  defp status_label(%IndexerProgress{status: :error} = row), do: row.error || gettext("failed")

  @doc ~S(Time left on a Prowlarr pause, coarsest unit: "<1m", "12m", "3h", "1d".)
  def paused_remaining(%DateTime{} = till, now \\ DateTime.utc_now()) do
    seconds = DateTime.diff(till, now, :second)

    cond do
      seconds < 60 -> pgettext("pause time left", "<1m")
      seconds < 3_600 -> pgettext("pause time left", "%{minutes}m", minutes: div(seconds, 60))
      seconds < 86_400 -> pgettext("pause time left", "%{hours}h", hours: div(seconds, 3_600))
      true -> pgettext("pause time left", "%{days}d", days: div(seconds, 86_400))
    end
  end

  @doc """
  Drops pauses that have already lapsed. Health details are cached for minutes,
  so the list can name an indexer whose pause is over by render time.
  """
  def active_paused(paused, now \\ DateTime.utc_now()) do
    Enum.filter(paused, &(DateTime.compare(&1.disabled_till, now) == :gt))
  end

  @doc "\"Amber Tracker (12m left), Birch Tracker (3h left)\""
  def paused_list(paused) do
    Enum.map_join(paused, ", ", fn pause ->
      gettext("%{name} (%{remaining} left)",
        name: pause.name,
        remaining: paused_remaining(pause.disabled_till)
      )
    end)
  end

  def paused_heading(count) do
    ngettext(
      "%{count} indexer paused by Prowlarr",
      "%{count} indexers paused by Prowlarr",
      count
    )
  end

  @doc """
  Flash kind and text for the result of
  `Mydia.Indexers.retest_paused_prowlarr_indexers/1`.

  "Recovered" is claimed only when the re-read after the tests no longer lists
  the indexer as paused, so the flash never contradicts the status beside it.
  """
  def retest_flash({:ok, %{outcomes: []}}), do: {:info, gettext("No paused indexers to retest")}

  def retest_flash({:ok, %{outcomes: outcomes} = result}) do
    still_paused = result |> Map.get(:paused, []) |> MapSet.new(& &1.id)
    texts = Enum.map(outcomes, &retest_outcome_text(&1, still_paused))

    kind =
      if Enum.all?(texts, &match?({:recovered, _}, &1)), do: :info, else: :error

    {kind, Enum.map_join(texts, ". ", &elem(&1, 1))}
  end

  def retest_flash({:error, reason}),
    do: {:error, gettext("Retest failed: %{reason}", reason: reason)}

  defp retest_outcome_text({indexer, :ok}, still_paused) do
    if MapSet.member?(still_paused, indexer.id),
      do:
        {:still_paused,
         gettext("%{name} passed its test but Prowlarr still lists it as paused",
           name: indexer.name
         )},
      else: {:recovered, gettext("%{name} recovered", name: indexer.name)}
  end

  defp retest_outcome_text({indexer, {:error, message}}, _still_paused),
    do:
      {:failing,
       gettext("%{name} still failing: %{message}", name: indexer.name, message: message)}
end
