defmodule MydiaWeb.MediaLive.Show.SeasonComponents do
  @moduledoc """
  Per-season UI for the TV show page: the disclosure header and the episode
  list it toggles.
  """

  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.Helpers

  alias Mydia.Media.SeasonOrder
  alias MydiaWeb.MediaLive.Show.Components
  alias MydiaWeb.MediaLive.Show.SegmentComponents

  @doc """
  Season-ordering controls for a TVDB-sourced TV show: a persistent selector
  (any TVDB show, any time) and a dismissible suggestion banner (only when
  the show has never been asked and its official season looks wrong).

  Absent entirely for non-TVDB shows — there is nothing to switch between.
  """
  attr :media_item, :map, required: true
  attr :season_order_suggestion, :any, default: nil

  def season_order_controls(assigns) do
    ~H"""
    <div :if={tvdb_show?(@media_item)} class="mb-4 space-y-3">
      <div
        :if={@season_order_suggestion}
        id="season-order-suggestion"
        class="alert alert-info items-start"
      >
        <.icon name="hero-information-circle" class="w-5 h-5 shrink-0 mt-0.5" />
        <div class="flex-1">
          <p class="text-sm">
            One season here has {season_episode_max(@media_item)} episodes. TVDB also splits
            this show into {describe_counts(@season_order_suggestion.counts)} as a DVD ordering.
          </p>
          <div class="flex gap-2 mt-2">
            <button
              type="button"
              id="season-order-accept"
              class="btn btn-sm btn-primary"
              phx-click="change_season_order"
              phx-value-order="dvd"
            >
              Use DVD ordering
            </button>
            <button
              type="button"
              id="season-order-dismiss"
              class="btn btn-sm btn-ghost"
              phx-click="change_season_order"
              phx-value-order="official"
            >
              Keep aired order
            </button>
          </div>
        </div>
      </div>

      <form
        id="season-order-form"
        phx-change="change_season_order"
        class="flex items-center gap-2"
      >
        <label for="season-order-select" class="text-xs text-base-content/60">
          Episode ordering
        </label>
        <select id="season-order-select" name="order" class="select select-xs select-bordered w-auto">
          <option
            :for={order <- SeasonOrder.values()}
            value={order}
            selected={current_season_order(@media_item) == order}
          >
            {SeasonOrder.label(order)}
          </option>
        </select>
      </form>
    </div>
    """
  end

  defp tvdb_show?(media_item),
    do: media_item.type == "tv_show" and media_item.metadata_source == :tvdb

  defp current_season_order(media_item), do: media_item.season_order || :official

  defp season_episode_max(media_item) do
    media_item.episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.map(fn {_season_number, eps} -> length(eps) end)
    |> Enum.max(fn -> 0 end)
  end

  defp describe_counts([single]), do: "one season of #{single}"

  defp describe_counts(counts) do
    "#{season_count_word(length(counts))} seasons of #{join_with_and(counts)}"
  end

  defp join_with_and([last]), do: to_string(last)

  defp join_with_and(counts) do
    {init, [last]} = Enum.split(counts, -1)
    Enum.join(init, ", ") <> " and #{last}"
  end

  defp season_count_word(2), do: "two"
  defp season_count_word(3), do: "three"
  defp season_count_word(4), do: "four"
  defp season_count_word(5), do: "five"
  defp season_count_word(6), do: "six"
  defp season_count_word(n), do: to_string(n)

  @doc """
  One season: the disclosure header, the segment status row, and the episode
  list. The episode list (and the segment row) render only when expanded.
  """
  attr :season_number, :integer, required: true
  attr :episodes, :list, required: true
  attr :expanded?, :boolean, required: true
  attr :expanded_episodes, :any, required: true
  attr :expanded_chunks, :any, default: MapSet.new()
  attr :auto_searching_season, :any, default: nil
  attr :rescanning_season, :any, default: nil
  attr :auto_searching_episode, :any, default: nil
  attr :playback_enabled, :boolean, required: true
  attr :transcode_jobs, :map, default: %{}
  attr :segment_statuses, :map, default: %{}
  attr :segment_detection_available, :boolean, default: true

  def season_section(assigns) do
    ~H"""
    <div id={"season-#{@season_number}"} class="p-4">
      <.season_header
        season_number={@season_number}
        episodes={@episodes}
        expanded?={@expanded?}
        auto_searching_season={@auto_searching_season}
        rescanning_season={@rescanning_season}
      />

      <%= if @expanded? do %>
        <SegmentComponents.segment_status_row
          :if={@segment_detection_available}
          season_number={@season_number}
          status={Map.get(@segment_statuses, @season_number)}
        />

        <%!-- Episodes list, split into labelled ranges above the chunk threshold.
              One id owns "season-#{n}-episodes" regardless of branch, since
              the season disclosure's aria-controls always points at it. --%>
        <div id={"season-#{@season_number}-episodes"}>
          <%= for {{label, chunk_episodes}, index} <- Enum.with_index(episode_chunks(@episodes)) do %>
            <%= if is_nil(label) do %>
              <div class="bg-base-100 rounded-lg divide-y divide-base-200">
                <.episode_rows
                  episodes={chunk_episodes}
                  expanded_episodes={@expanded_episodes}
                  auto_searching_episode={@auto_searching_episode}
                  playback_enabled={@playback_enabled}
                  transcode_jobs={@transcode_jobs}
                />
              </div>
            <% else %>
              <% expanded_chunk? =
                chunk_expanded?(@expanded_chunks, @season_number, label, index == 0) %>
              <button
                type="button"
                id={"season-#{@season_number}-chunk-#{label}-toggle"}
                class="flex items-center gap-2 w-full px-3 py-2 text-left hover:bg-base-200 rounded-lg"
                phx-click="toggle_episode_chunk"
                phx-value-season-number={@season_number}
                phx-value-chunk-label={label}
                aria-expanded={to_string(expanded_chunk?)}
                aria-controls={"season-#{@season_number}-chunk-#{label}"}
              >
                <.icon
                  name={if expanded_chunk?, do: "hero-chevron-down", else: "hero-chevron-right"}
                  class="w-4 h-4 text-base-content/40"
                />
                <span class="text-sm font-medium">Episodes {label}</span>
                <span class="text-xs text-base-content/60">{length(chunk_episodes)}</span>
              </button>
              <div
                :if={expanded_chunk?}
                id={"season-#{@season_number}-chunk-#{label}"}
                class="bg-base-100 rounded-lg divide-y divide-base-200"
              >
                <.episode_rows
                  episodes={chunk_episodes}
                  expanded_episodes={@expanded_episodes}
                  auto_searching_episode={@auto_searching_episode}
                  playback_enabled={@playback_enabled}
                  transcode_jobs={@transcode_jobs}
                />
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # The newest chunk (index 0, since `episode_chunks/1` returns newest-first)
  # starts expanded without a click. `expanded_chunks` records keys *toggled
  # away from their default*, so membership means something different per
  # chunk: for the newest chunk, present means collapsed (the user closed the
  # one that opened itself); for every other chunk, present means expanded
  # (the ordinary click-to-open meaning). This keeps the initial MapSet empty
  # — no per-season mount-time computation — at the cost of that inversion.
  defp chunk_expanded?(expanded_chunks, season_number, label, newest?) do
    toggled? = MapSet.member?(expanded_chunks, {season_number, label})
    if newest?, do: !toggled?, else: toggled?
  end

  # One chunk's worth of episode rows: episode number, title, quality/air-date
  # metadata, status chip, action buttons, and the expanded file-details panel.
  #
  # Shared between the unlabelled (single-chunk) and labelled-range branches of
  # season_section/1 so both render identical rows.
  attr :episodes, :list, required: true
  attr :expanded_episodes, :any, required: true
  attr :auto_searching_episode, :any, default: nil
  attr :playback_enabled, :boolean, required: true
  attr :transcode_jobs, :map, default: %{}

  defp episode_rows(assigns) do
    ~H"""
    <%= for episode <- @episodes do %>
      <% has_files = length(episode.media_files) > 0
      is_expanded = MapSet.member?(@expanded_episodes, episode.id)
      status = get_episode_status(episode) %>

      <div class={["py-2 px-3", has_files && "border-l-2 border-l-success"]}>
        <%!-- Mobile: two rows. Desktop: single row --%>
        <div class="flex flex-col sm:flex-row sm:items-center gap-1 sm:gap-3">
          <%!-- Row 1: Episode number + Title --%>
          <div class="flex items-center gap-1 flex-1 min-w-0">
            <%!-- Episode number with expand toggle --%>
            <div
              class={[
                "flex items-center flex-shrink-0",
                has_files && "gap-1 cursor-pointer hover:text-primary"
              ]}
              phx-click={has_files && "toggle_episode_expanded"}
              phx-value-episode-id={episode.id}
            >
              <%= if has_files do %>
                <.icon
                  name={if is_expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                  class="w-3 h-3 text-base-content/40"
                />
              <% end %>
              <span class="font-mono text-sm font-medium text-base-content/70">
                {episode.episode_number}
              </span>
            </div>

            <%!-- Title --%>
            <div
              class={["flex-1 min-w-0", has_files && "cursor-pointer"]}
              phx-click={has_files && "toggle_episode_expanded"}
              phx-value-episode-id={episode.id}
            >
              <span class={[
                "text-sm font-medium truncate block",
                has_files && "hover:text-primary"
              ]}>
                {episode.title || "TBA"}
              </span>
            </div>
          </div>

          <%!-- Row 2 on mobile / inline on desktop: metadata + actions --%>
          <div class="flex items-center justify-between sm:justify-end gap-2 sm:pl-0">
            <%!-- Metadata: quality + air date --%>
            <div class="flex items-center gap-2 text-xs text-base-content/50">
              <%= if quality = get_episode_quality_badge(episode) do %>
                <span class="badge badge-primary badge-xs">{quality}</span>
              <% end %>
              <%= if episode.air_date do %>
                <span>{format_date(episode.air_date)}</span>
              <% end %>
            </div>

            <%!-- Status + Actions --%>
            <div class="flex items-center gap-1 flex-shrink-0">
              <%!-- Status indicator --%>
              <div class="tooltip tooltip-left" data-tip={episode_status_tooltip(episode)}>
                <span class={["badge badge-xs", episode_status_color(status)]}>
                  <.icon name={episode_status_icon(status)} class="w-3 h-3" />
                </span>
              </div>
              <%= if @playback_enabled && has_files do %>
                <% episode_best_file = get_best_media_file(episode.media_files) %>
                <a
                  href={
                    flutter_player_url("episode", episode.id,
                      file_id: episode_best_file.id,
                      title: episode.title
                    )
                  }
                  class="btn btn-success btn-sm btn-square"
                  title="Play"
                >
                  <.icon name="hero-play-solid" class="w-4 h-4" />
                </a>
              <% end %>
              <button
                type="button"
                phx-click="auto_search_episode"
                phx-value-episode-id={episode.id}
                class="btn btn-primary btn-sm btn-square"
                disabled={@auto_searching_episode == episode.id}
                title="Auto search"
              >
                <%= if @auto_searching_episode == episode.id do %>
                  <span class="loading loading-spinner loading-sm"></span>
                <% else %>
                  <.icon name="hero-bolt" class="w-4 h-4" />
                <% end %>
              </button>
              <button
                type="button"
                phx-click="search_episode"
                phx-value-episode-id={episode.id}
                class="btn btn-ghost btn-sm btn-square"
                title="Manual search"
              >
                <.icon name="hero-magnifying-glass" class="w-4 h-4" />
              </button>
              <button
                type="button"
                phx-click="toggle_episode_monitored"
                phx-value-episode-id={episode.id}
                class={[
                  "btn btn-sm btn-square",
                  if(episode.monitored, do: "btn-ghost", else: "btn-ghost opacity-40")
                ]}
                title={if episode.monitored, do: "Stop monitoring", else: "Start monitoring"}
              >
                <.icon
                  name={if episode.monitored, do: "hero-bookmark-solid", else: "hero-bookmark"}
                  class="w-4 h-4"
                />
              </button>
            </div>
          </div>
        </div>

        <%!-- Expanded file details --%>
        <%= if is_expanded && has_files do %>
          <div class="mt-2 ml-8 space-y-1">
            <div :for={file <- episode.media_files} class="bg-base-200/50 rounded p-2">
              <Components.episode_file_row
                file={file}
                episode={episode}
                playback_enabled={@playback_enabled}
                transcode_jobs={Map.get(@transcode_jobs, file.id, [])}
              />
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  @doc """
  The disclosure row: a toggle button carrying the chevron, badge, counts,
  progress bar, and status chip, with the five season action buttons as
  siblings (so a click on "auto search" does not also collapse the season).
  """
  attr :season_number, :integer, required: true
  attr :episodes, :list, required: true
  attr :expanded?, :boolean, required: true
  attr :auto_searching_season, :any, default: nil
  attr :rescanning_season, :any, default: nil

  def season_header(assigns) do
    counts = season_episode_counts(assigns.episodes)
    season_state = Mydia.Media.season_monitoring_state(assigns.episodes)

    chip =
      cond do
        counts.missing > 0 ->
          %{class: "badge badge-warning", label: "#{counts.missing} missing"}

        counts.upcoming > 0 ->
          %{class: "badge badge-ghost", label: "#{counts.upcoming} upcoming"}

        counts.available == counts.total ->
          %{class: "badge badge-success", label: "complete"}

        true ->
          nil
      end

    assigns =
      assign(assigns, :counts, counts)
      |> assign(:season_state, season_state)
      |> assign(:chip, chip)

    ~H"""
    <div class="flex flex-wrap items-center gap-2 mb-3">
      <button
        type="button"
        id={"season-#{@season_number}-toggle"}
        class="flex flex-wrap items-center gap-2 cursor-pointer text-left"
        phx-click="toggle_season_expanded"
        phx-value-season-number={@season_number}
        aria-expanded={to_string(@expanded?)}
        aria-controls={"season-#{@season_number}-episodes"}
      >
        <.icon
          name={if @expanded?, do: "hero-chevron-down", else: "hero-chevron-right"}
          class="w-4 h-4 text-base-content/40"
        />
        <span class="badge badge-primary badge-lg font-bold shrink-0">S{@season_number}</span>
        <span class="text-sm text-base-content/70 shrink-0">{@counts.available}/{@counts.total}</span>
        <progress
          class="progress progress-success w-16 shrink-0"
          value={@counts.available}
          max={@counts.total}
        ></progress>
        <%= if @chip do %>
          <span class={@chip.class}>{@chip.label}</span>
        <% end %>
      </button>

      <%!-- Season actions: siblings of the toggle, so they never collapse it --%>
      <div class="flex items-center gap-1">
        <div class="tooltip tooltip-bottom" data-tip="Auto search season">
          <button
            type="button"
            id={"season-#{@season_number}-auto-search"}
            phx-click="auto_search_season"
            phx-value-season-number={@season_number}
            aria-label="Auto search season"
            class="btn btn-sm btn-primary"
            disabled={@auto_searching_season == @season_number}
          >
            <%= if @auto_searching_season == @season_number do %>
              <span class="loading loading-spinner loading-sm"></span>
            <% else %>
              <.icon name="hero-bolt" class="w-4 h-4" />
            <% end %>
          </button>
        </div>
        <div class="tooltip tooltip-bottom" data-tip="Manual search">
          <button
            type="button"
            phx-click="manual_search_season"
            phx-value-season-number={@season_number}
            aria-label="Manual search"
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-magnifying-glass" class="w-4 h-4" />
          </button>
        </div>
        <div class="tooltip tooltip-bottom" data-tip="Re-scan">
          <button
            type="button"
            phx-click="rescan_season"
            phx-value-season-number={@season_number}
            aria-label="Re-scan"
            class="btn btn-sm btn-ghost"
            disabled={@rescanning_season == @season_number}
          >
            <%= if @rescanning_season == @season_number do %>
              <span class="loading loading-spinner loading-sm"></span>
            <% else %>
              <.icon name="hero-arrow-path" class="w-4 h-4" />
            <% end %>
          </button>
        </div>
        <div
          class="tooltip tooltip-bottom"
          data-tip={season_monitoring_tooltip(@season_state)}
        >
          <button
            type="button"
            id={"season-#{@season_number}-monitor-toggle"}
            phx-click={if @season_state == :all, do: "unmonitor_season", else: "monitor_season"}
            phx-value-season-number={@season_number}
            aria-label={season_monitoring_tooltip(@season_state)}
            class={[
              "btn btn-sm btn-ghost",
              @season_state == :none && "opacity-60"
            ]}
          >
            <.monitoring_icon state={@season_state} class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Bookmark icon for a season's derived monitoring state.

  - `:all` - solid bookmark
  - `:partial` - half-filled, built from two stacked icons
  - `:none` - outline bookmark
  """
  attr :state, :atom, required: true
  attr :class, :string, default: "w-5 h-5"

  def monitoring_icon(%{state: :all} = assigns) do
    ~H"""
    <.icon name="hero-bookmark-solid" class={@class} />
    """
  end

  def monitoring_icon(%{state: :none} = assigns) do
    ~H"""
    <.icon name="hero-bookmark" class={@class} />
    """
  end

  def monitoring_icon(assigns) do
    ~H"""
    <span class="relative inline-flex">
      <.icon name="hero-bookmark" class={@class} />
      <span class="absolute inset-0 overflow-hidden" style="clip-path: inset(50% 0 0 0);">
        <.icon name="hero-bookmark-solid" class={@class} />
      </span>
    </span>
    """
  end
end
