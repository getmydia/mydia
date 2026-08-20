defmodule MydiaWeb.MediaLive.Show.SeasonComponents do
  @moduledoc """
  Per-season UI for the TV show page: the disclosure header and the episode
  list it toggles.
  """

  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.Helpers

  alias MydiaWeb.MediaLive.Show.Components
  alias MydiaWeb.MediaLive.Show.SegmentComponents

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
      status = get_episode_status(episode)
      quality = get_episode_quality_badge(episode) %>

      <div class={["py-2 px-3", has_files && "border-l-2 border-l-success"]}>
        <%!-- Mobile keeps two stacked rows. From sm up every wrapper collapses to
              `display: contents`, which dissolves the boxes and promotes the cells
              to items of one grid with fixed tracks. That is what makes quality,
              air date and status form columns down the whole season instead of
              drifting with each row's content. --%>
        <div class={[
          "flex flex-col gap-1",
          "sm:grid sm:items-center sm:gap-x-3 sm:gap-y-0",
          "sm:grid-cols-[2.75rem_minmax(0,1fr)_3.5rem_5.5rem_2rem_auto]",
          "lg:grid-cols-[2.75rem_minmax(0,1fr)_3.5rem_5.5rem_7rem_auto]"
        ]}>
          <div class="flex items-center gap-1 flex-1 min-w-0 sm:contents">
            <%!-- Chevron and number share one cell so they stay a single
                  toggle_episode_expanded target. ml-auto right-aligns the number,
                  which keeps two- and three-digit episodes in column: the chunk
                  threshold is 50, and TVDB puts 170 Black Clover episodes in one
                  season. --%>
            <div
              class={[
                "flex items-center gap-1 flex-shrink-0 sm:w-full",
                has_files && "cursor-pointer hover:text-primary"
              ]}
              phx-click={has_files && "toggle_episode_expanded"}
              phx-value-episode-id={episode.id}
            >
              <.icon
                :if={has_files}
                name={if is_expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
                class="w-3 h-3 text-base-content/40"
              />
              <span class="font-mono text-sm font-medium text-base-content/70 tabular-nums sm:ml-auto">
                {episode.episode_number}
              </span>
            </div>

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

          <div class="flex items-center justify-between gap-2 sm:contents">
            <div class="flex items-center gap-2 sm:contents">
              <div class="flex items-center sm:justify-end">
                <span :if={quality} class="badge badge-sm badge-ghost font-mono tabular-nums">
                  {quality}
                </span>
              </div>
              <div class="text-xs text-base-content/50 tabular-nums sm:text-right">
                {episode.air_date && format_date(episode.air_date)}
              </div>
            </div>

            <div class="flex items-center gap-2 sm:contents">
              <%!-- badge-sm (24px), not badge-xs (16px), and carrying its label at
                    lg and up. The tooltip stays: the label names the state, the
                    tooltip still lists the filenames. It wraps the chip from the
                    outside, never a join-item. --%>
              <div
                class="tooltip tooltip-left min-w-0 sm:justify-self-end"
                data-tip={episode_status_tooltip(episode)}
              >
                <span
                  id={"episode-#{episode.id}-status"}
                  class={["badge badge-sm gap-1 max-w-full", episode_status_color(status)]}
                >
                  <.icon name={episode_status_icon(status)} class="w-3 h-3 shrink-0" />
                  <span class="hidden lg:inline truncate">{episode_status_label(status)}</span>
                </span>
              </div>

              <%!-- One toolbar, not four loose squares. The divider rule lives on
                    the container because btn-ghost has no border of its own and
                    the first item varies: the play slot is absent whenever
                    playback is off. --%>
              <div class="flex-shrink-0 sm:justify-self-end sm:border-l sm:border-base-300 sm:pl-3">
                <div class="join border border-base-300 rounded-lg [&>*:not(:first-child)]:border-l [&>*:not(:first-child)]:border-base-300">
                  <%= if @playback_enabled do %>
                    <%= if has_files do %>
                      <% best_file = get_best_media_file(episode.media_files) %>
                      <a
                        id={"episode-#{episode.id}-play"}
                        href={
                          flutter_player_url("episode", episode.id,
                            file_id: best_file.id,
                            title: episode.title
                          )
                        }
                        class="join-item btn btn-sm btn-square btn-ghost"
                        title="Play"
                        aria-label="Play"
                      >
                        <.icon name="hero-play-solid" class="w-4 h-4" />
                      </a>
                    <% else %>
                      <%!-- `disabled` does nothing on an anchor, so the two states
                            are different elements filling the same 32px box. --%>
                      <button
                        id={"episode-#{episode.id}-play"}
                        type="button"
                        class="join-item btn btn-sm btn-square btn-ghost"
                        disabled
                        title="No file yet"
                        aria-label="Play, no file yet"
                      >
                        <.icon name="hero-play-solid" class="w-4 h-4" />
                      </button>
                    <% end %>
                  <% end %>

                  <button
                    id={"episode-#{episode.id}-auto-search"}
                    type="button"
                    phx-click="auto_search_episode"
                    phx-value-episode-id={episode.id}
                    class="join-item btn btn-sm btn-square btn-ghost"
                    disabled={@auto_searching_episode == episode.id}
                    title="Auto search"
                    aria-label="Auto search"
                  >
                    <%= if @auto_searching_episode == episode.id do %>
                      <span class="loading loading-spinner loading-sm"></span>
                    <% else %>
                      <.icon name="hero-bolt" class="w-4 h-4 text-primary" />
                    <% end %>
                  </button>

                  <button
                    id={"episode-#{episode.id}-manual-search"}
                    type="button"
                    phx-click="search_episode"
                    phx-value-episode-id={episode.id}
                    class="join-item btn btn-sm btn-square btn-ghost"
                    title="Manual search"
                    aria-label="Manual search"
                  >
                    <.icon name="hero-magnifying-glass" class="w-4 h-4" />
                  </button>

                  <%!-- Muting moves to the icon. opacity-40 on the button dimmed
                        the focus ring with it. --%>
                  <button
                    id={"episode-#{episode.id}-monitor"}
                    type="button"
                    phx-click="toggle_episode_monitored"
                    phx-value-episode-id={episode.id}
                    class="join-item btn btn-sm btn-square btn-ghost"
                    title={if episode.monitored, do: "Stop monitoring", else: "Start monitoring"}
                    aria-label={if episode.monitored, do: "Stop monitoring", else: "Start monitoring"}
                  >
                    <.icon
                      name={if episode.monitored, do: "hero-bookmark-solid", else: "hero-bookmark"}
                      class={
                        if episode.monitored, do: "w-4 h-4", else: "w-4 h-4 text-base-content/40"
                      }
                    />
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

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
