defmodule MydiaWeb.MediaLive.Show.Components do
  @moduledoc """
  UI component sections for the MediaLive.Show page.
  """
  use MydiaWeb, :html
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.Helpers

  alias MydiaWeb.MediaLive.Show.SegmentComponents

  @doc """
  Hero section with backdrop image, poster, and quick action buttons.
  """
  attr :media_item, :map, required: true
  attr :playback_enabled, :boolean, required: true
  attr :next_episode, :map, default: nil
  attr :next_episode_state, :atom, default: nil
  attr :auto_searching, :boolean, required: true
  attr :downloads_with_status, :list, required: true
  attr :quality_profiles, :list, required: true
  attr :default_quality_profile_name, :string, default: nil
  attr :applying_monitoring_preset, :boolean, default: false
  attr :is_favorite, :boolean, default: false
  attr :item_collections, :list, default: []
  attr :user_collections, :list, default: []

  @monitoring_presets [
    {:all, "All Episodes", "Monitor all episodes"},
    {:future, "Future Episodes", "Only unaired episodes"},
    {:missing, "Missing Episodes", "Episodes without files"},
    {:existing, "Existing Episodes", "Only episodes with files"},
    {:first_season, "First Season", "Only season 1"},
    {:latest_season, "Latest Season", "Latest + future seasons"},
    {:none, "None", "Don't monitor any episodes"}
  ]

  def hero_section(assigns) do
    assigns = assign(assigns, :monitoring_presets, @monitoring_presets)

    ~H"""
    <%!-- Left Column: Poster and Quick Actions --%>
    <div class="w-full md:w-64 lg:w-80 flex-shrink-0">
      <%!-- Poster - centered and smaller on mobile --%>
      <div class="card bg-base-100 shadow-xl mb-4 mx-auto w-48 sm:w-56 md:w-full">
        <figure class="aspect-[2/3] bg-base-300 overflow-hidden rounded-t-2xl">
          <img
            src={get_poster_url(@media_item)}
            alt={@media_item.title}
            class="w-full h-full object-cover"
          />
        </figure>
      </div>

      <%!-- Quick Actions --%>
      <div class="flex flex-col gap-2">
        <%!-- Play Button (for content with media files) --%>
        <%= if @playback_enabled && @media_item.type == "movie" && length(@media_item.media_files) > 0 do %>
          <% best_file = get_best_media_file(@media_item.media_files) %>
          <a
            href={
              flutter_player_url("movie", @media_item.id,
                file_id: best_file.id,
                title: @media_item.title
              )
            }
            class="btn btn-primary btn-block"
          >
            <.icon name="hero-play-circle-solid" class="w-5 h-5" /> Play Movie
          </a>

          <div class="divider my-1"></div>
        <% end %>

        <%!-- Play Next Button (for TV shows with next episode) --%>
        <%= if @playback_enabled && @media_item.type == "tv_show" && @next_episode do %>
          <% next_best_file = get_best_media_file(@next_episode.media_files) %>
          <%= if next_best_file do %>
            <a
              href={
                flutter_player_url("episode", @next_episode.id,
                  file_id: next_best_file.id,
                  title: @next_episode.title
                )
              }
              class="btn btn-primary btn-block"
            >
              <.icon name="hero-play-circle-solid" class="w-5 h-5" />
              {next_episode_button_text(@next_episode_state)}
            </a>

            <div class="divider my-1"></div>
          <% end %>
        <% end %>

        <div class="grid grid-cols-2 gap-2">
          <div class="col-span-2">
            <div class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-1">
              Search
            </div>
          </div>
          <button
            type="button"
            phx-click="auto_search_download"
            class="btn btn-primary"
            disabled={@auto_searching || !can_auto_search?(@media_item, @downloads_with_status)}
          >
            <%= if @auto_searching do %>
              <span class="loading loading-spinner loading-sm"></span> Searching...
            <% else %>
              <.icon name="hero-bolt" class="w-5 h-5" /> Auto
            <% end %>
          </button>
          <button
            type="button"
            phx-click="manual_search"
            class="btn btn-outline"
          >
            <.icon name="hero-magnifying-glass" class="w-5 h-5" /> Manual
          </button>

          <%!-- Favorite and Collection actions --%>
          <button
            type="button"
            phx-click="toggle_favorite"
            class={[
              "btn",
              @is_favorite && "btn-error",
              !@is_favorite && "btn-outline"
            ]}
            title={if @is_favorite, do: "Remove from Favorites", else: "Add to Favorites"}
          >
            <.icon
              name={if @is_favorite, do: "hero-heart-solid", else: "hero-heart"}
              class="w-5 h-5"
            />
            <span class="hidden sm:inline">{if @is_favorite, do: "Favorited", else: "Favorite"}</span>
          </button>

          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-outline w-full">
              <.icon name="hero-folder-plus" class="w-5 h-5" />
              <span class="hidden sm:inline">Collection</span>
              <.icon name="hero-chevron-down" class="w-3 h-3 opacity-70" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-56 border border-base-300"
            >
              <%= if Enum.empty?(@user_collections) do %>
                <li class="menu-title px-2 py-1 text-base-content/50 text-sm">
                  No collections yet
                </li>
                <li>
                  <.link navigate={~p"/collections"} class="justify-start">
                    <.icon name="hero-plus" class="w-4 h-4" /> Create Collection
                  </.link>
                </li>
              <% else %>
                <li class="menu-title px-2 py-1 text-base-content/50 text-xs uppercase">
                  Your Collections
                </li>
                <%= for collection <- @user_collections do %>
                  <% is_in_collection = Enum.any?(@item_collections, &(&1.id == collection.id)) %>
                  <li>
                    <button
                      type="button"
                      phx-click={
                        if is_in_collection, do: "remove_from_collection", else: "add_to_collection"
                      }
                      phx-value-collection-id={collection.id}
                      class="justify-between"
                    >
                      <span class="flex items-center gap-2">
                        <.icon
                          name={if collection.is_system, do: "hero-star", else: "hero-folder"}
                          class="w-4 h-4"
                        />
                        {collection.name}
                      </span>
                      <%= if is_in_collection do %>
                        <.icon name="hero-check" class="w-4 h-4 text-success" />
                      <% end %>
                    </button>
                  </li>
                <% end %>
                <div class="divider my-1"></div>
                <li>
                  <.link navigate={~p"/collections"} class="justify-start">
                    <.icon name="hero-folder-open" class="w-4 h-4" /> Manage Collections
                  </.link>
                </li>
              <% end %>
            </ul>
          </div>
        </div>

        <%!-- Secondary actions --%>
        <div class="flex flex-col gap-2">
          <%= if @media_item.type == "tv_show" do %>
            <%!-- Monitoring Preset Dropdown (TV shows only) --%>
            <div class="dropdown dropdown-end w-full">
              <div
                tabindex="0"
                role="button"
                class={[
                  "btn w-full",
                  @media_item.monitored && "btn-success",
                  !@media_item.monitored && "btn-ghost"
                ]}
                disabled={@applying_monitoring_preset}
              >
                <%= if @applying_monitoring_preset do %>
                  <span class="loading loading-spinner loading-xs"></span>
                <% else %>
                  <.monitoring_icon
                    preset={@media_item.monitoring_preset}
                    class="w-5 h-5"
                  />
                <% end %>
                <span>
                  {monitoring_preset_label(@media_item.monitoring_preset)}
                </span>
                <.icon name="hero-chevron-down" class="w-3 h-3 opacity-70" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-64 border border-base-300"
              >
                <li :for={{preset, label, description} <- @monitoring_presets}>
                  <button
                    type="button"
                    phx-click="apply_monitoring_preset"
                    phx-value-preset={preset}
                    class={[
                      "flex flex-col items-start",
                      @media_item.monitoring_preset == preset && "active"
                    ]}
                  >
                    <span class="font-medium">{label}</span>
                    <span class="text-xs text-base-content/60">{description}</span>
                  </button>
                </li>
              </ul>
            </div>
          <% else %>
            <%!-- Simple monitored toggle for movies --%>
            <button
              type="button"
              phx-click="toggle_monitored"
              class={[
                "btn w-full",
                @media_item.monitored && "btn-success",
                !@media_item.monitored && "btn-ghost"
              ]}
            >
              <.icon
                name={if @media_item.monitored, do: "hero-bookmark-solid", else: "hero-bookmark"}
                class="w-5 h-5"
              />
              <span>
                {if @media_item.monitored, do: "Monitored", else: "Not Monitored"}
              </span>
            </button>
          <% end %>
        </div>

        <%!-- Info Cards --%>
        <div class="rounded-box bg-base-200/50 p-2 space-y-1 mt-3">
          <%!-- Quality Profile --%>
          <div class="dropdown dropdown-end w-full">
            <div
              tabindex="0"
              role="button"
              class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg cursor-pointer hover:bg-base-300/50 transition-colors w-full group"
              title="Click to change quality profile"
            >
              <div class="w-8 h-8 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0">
                <.icon name="hero-adjustments-horizontal" class="w-4 h-4 text-primary" />
              </div>
              <div class="flex-1 min-w-0">
                <div class="text-xs text-base-content/50">Quality Profile</div>
                <div class="text-sm font-medium truncate">
                  <%= if @media_item.quality_profile do %>
                    {@media_item.quality_profile.name}
                  <% else %>
                    <span class="text-base-content/40">Not Set</span>
                  <% end %>
                </div>
              </div>
              <.icon
                name="hero-chevron-right"
                class="w-4 h-4 text-base-content/30 group-hover:text-base-content/60 transition-colors flex-shrink-0"
              />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-52 border border-base-300"
            >
              <li>
                <button
                  type="button"
                  phx-click="update_quality_profile"
                  phx-value-profile-id=""
                  class={[
                    "justify-between",
                    is_nil(@media_item.quality_profile_id) && "active"
                  ]}
                >
                  {default_quality_profile_label(@default_quality_profile_name)}
                  <%= if is_nil(@media_item.quality_profile_id) do %>
                    <.icon name="hero-check" class="w-4 h-4" />
                  <% end %>
                </button>
              </li>
              <li :for={profile <- @quality_profiles}>
                <button
                  type="button"
                  phx-click="update_quality_profile"
                  phx-value-profile-id={profile.id}
                  class={[
                    "justify-between",
                    @media_item.quality_profile_id == profile.id && "active"
                  ]}
                >
                  {profile.name}
                  <%= if @media_item.quality_profile_id == profile.id do %>
                    <.icon name="hero-check" class="w-4 h-4" />
                  <% end %>
                </button>
              </li>
            </ul>
          </div>

          <%!-- Category --%>
          <button
            type="button"
            phx-click="show_category_modal"
            class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg cursor-pointer hover:bg-base-300/50 transition-colors w-full group"
            title="Click to change category"
          >
            <div class="w-8 h-8 rounded-lg bg-secondary/10 flex items-center justify-center flex-shrink-0">
              <.icon name="hero-tag" class="w-4 h-4 text-secondary" />
            </div>
            <div class="flex-1 min-w-0 text-left">
              <div class="text-xs text-base-content/50">Category</div>
              <div class="text-sm font-medium">
                <%= if @media_item.category do %>
                  <.category_badge
                    category={@media_item.category}
                    override={@media_item.category_override}
                  />
                <% else %>
                  <span class="badge badge-ghost badge-sm">
                    {if @media_item.type == "movie", do: "Movie", else: "TV Show"}
                  </span>
                <% end %>
              </div>
            </div>
            <.icon
              name="hero-chevron-right"
              class="w-4 h-4 text-base-content/30 group-hover:text-base-content/60 transition-colors flex-shrink-0"
            />
          </button>

          <%!-- Path --%>
          <%= if path = get_media_path(@media_item) do %>
            <div class="flex items-center gap-2.5 px-2 py-1.5">
              <div class="w-8 h-8 rounded-lg bg-accent/10 flex items-center justify-center flex-shrink-0">
                <.icon name="hero-folder" class="w-4 h-4 text-accent" />
              </div>
              <div class="flex-1 min-w-0">
                <div class="text-xs text-base-content/50">Path</div>
                <div class="text-xs font-mono truncate" title={path}>
                  {path}
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Compact secondary info section with overview, trailer, and cast.
  Uses the same compact inline layout for both TV shows and movies.
  """
  attr :media_item, :map, required: true

  def overview_section(assigns) do
    cast = get_cast(assigns.media_item)
    crew = get_crew(assigns.media_item)
    trailer_url = get_trailer_embed_url(assigns.media_item)
    has_cast_crew = cast != [] or crew != []

    assigns =
      assigns
      |> assign(:cast, cast)
      |> assign(:crew, crew)
      |> assign(:trailer_url, trailer_url)
      |> assign(:has_cast_crew, has_cast_crew)

    ~H"""
    <%!-- Compact inline layout for both TV shows and movies --%>
    <div class="flex flex-wrap items-start gap-4 mb-4 text-sm">
      <%!-- Overview text --%>
      <p class="flex-1 min-w-[200px] text-base-content/70 leading-relaxed line-clamp-2">
        {get_overview(@media_item)}
      </p>

      <%!-- Action buttons for trailer and cast --%>
      <div class="flex items-center gap-2 flex-shrink-0">
        <%= if @trailer_url do %>
          <button
            type="button"
            phx-click="show_trailer_modal"
            class="btn btn-sm btn-ghost gap-1"
          >
            <.icon name="hero-play-circle" class="w-4 h-4 text-primary" />
            <span>Trailer</span>
          </button>
        <% end %>

        <%= if @has_cast_crew do %>
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-sm btn-ghost gap-1">
              <.icon name="hero-users" class="w-4 h-4 text-primary" />
              <span>Cast</span>
              <.icon name="hero-chevron-down" class="w-3 h-3 opacity-60" />
            </div>
            <div
              tabindex="0"
              class="dropdown-content z-50 card card-compact w-72 p-2 shadow-xl bg-base-100 border border-base-300"
            >
              <div class="card-body p-3">
                <%= if @crew != [] do %>
                  <div class="mb-3">
                    <div class="text-xs font-semibold text-base-content/50 uppercase mb-2">
                      Crew
                    </div>
                    <div class="space-y-1">
                      <div :for={member <- Enum.take(@crew, 3)} class="text-sm">
                        <span class="font-medium">{member.name}</span>
                        <span class="text-base-content/60">— {member.job}</span>
                      </div>
                    </div>
                  </div>
                <% end %>
                <%= if @cast != [] do %>
                  <div class="text-xs font-semibold text-base-content/50 uppercase mb-2">
                    Cast
                  </div>
                  <div class="space-y-1.5">
                    <div :for={actor <- Enum.take(@cast, 6)} class="flex items-center gap-2">
                      <div class="avatar">
                        <div class="w-6 h-6 rounded-full bg-base-300">
                          <%= if get_profile_image_url(actor.profile_path) do %>
                            <img src={get_profile_image_url(actor.profile_path)} alt={actor.name} />
                          <% else %>
                            <div class="flex items-center justify-center h-full">
                              <.icon name="hero-user" class="w-3 h-3 text-base-content/30" />
                            </div>
                          <% end %>
                        </div>
                      </div>
                      <div class="text-sm">
                        <span class="font-medium">{actor.name}</span>
                        <span class="text-base-content/60 text-xs">as {actor.character}</span>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Episodes section for TV shows with non-collapsible seasons.
  """
  attr :media_item, :map, required: true
  attr :expanded_seasons, :map, required: true
  attr :expanded_episodes, :map, default: MapSet.new()
  attr :auto_searching_season, :any, default: nil
  attr :rescanning_season, :any, default: nil
  attr :auto_searching_episode, :any, default: nil
  attr :playback_enabled, :boolean, required: true
  attr :transcode_jobs, :map, default: %{}
  attr :segment_statuses, :map, default: %{}
  attr :segment_detection_available, :boolean, default: true

  def episodes_section(assigns) do
    ~H"""
    <%= if @media_item.type == "tv_show" && length(@media_item.episodes) > 0 do %>
      <% grouped_seasons = group_episodes_by_season(@media_item.episodes) %>

      <div class="card bg-base-200 shadow-lg">
        <%!-- Card header with stats --%>
        <div class="card-body p-4 pb-0">
          <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
            <h2 class="card-title text-lg">Seasons & Episodes</h2>
            <div class="flex items-center gap-2 sm:gap-4 text-sm flex-wrap">
              <span class="text-base-content/60">
                {length(grouped_seasons)} seasons
              </span>
              <span class="text-base-content/60">•</span>
              <span class="text-success">
                {Enum.count(@media_item.episodes, &(length(&1.media_files) > 0))} available
              </span>
              <span class="text-base-content/60">/</span>
              <span>{length(@media_item.episodes)} total</span>
            </div>
          </div>
          <SegmentComponents.segment_unavailable_note :if={!@segment_detection_available} />
        </div>

        <%!-- All seasons in one container --%>
        <div class="divide-y divide-base-300">
          <%= for {season_num, episodes} <- grouped_seasons do %>
            <% season_available = Enum.count(episodes, &(length(&1.media_files) > 0))
            season_total = length(episodes) %>

            <div class="p-4">
              <%!-- Season header row --%>
              <div class="flex flex-wrap items-center gap-2 mb-3">
                <span class="badge badge-primary badge-lg font-bold shrink-0">S{season_num}</span>
                <span class="text-sm text-base-content/70 shrink-0">
                  {season_available}/{season_total}
                </span>
                <progress
                  class="progress progress-success w-16 shrink-0"
                  value={season_available}
                  max={season_total}
                ></progress>

                <%!-- Season actions --%>
                <div class="flex items-center gap-1">
                  <div class="tooltip tooltip-bottom" data-tip="Auto search season">
                    <button
                      type="button"
                      phx-click="auto_search_season"
                      phx-value-season-number={season_num}
                      class="btn btn-sm btn-primary"
                      disabled={@auto_searching_season == season_num}
                    >
                      <%= if @auto_searching_season == season_num do %>
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
                      phx-value-season-number={season_num}
                      class="btn btn-sm btn-ghost"
                    >
                      <.icon name="hero-magnifying-glass" class="w-4 h-4" />
                    </button>
                  </div>
                  <div class="tooltip tooltip-bottom" data-tip="Re-scan">
                    <button
                      type="button"
                      phx-click="rescan_season"
                      phx-value-season-number={season_num}
                      class="btn btn-sm btn-ghost"
                      disabled={@rescanning_season == season_num}
                    >
                      <%= if @rescanning_season == season_num do %>
                        <span class="loading loading-spinner loading-sm"></span>
                      <% else %>
                        <.icon name="hero-arrow-path" class="w-4 h-4" />
                      <% end %>
                    </button>
                  </div>
                  <div class="tooltip tooltip-bottom" data-tip="Monitor all">
                    <button
                      type="button"
                      phx-click="monitor_season"
                      phx-value-season-number={season_num}
                      class="btn btn-sm btn-ghost"
                    >
                      <.icon name="hero-bookmark-solid" class="w-4 h-4" />
                    </button>
                  </div>
                  <div class="tooltip tooltip-bottom" data-tip="Unmonitor all">
                    <button
                      type="button"
                      phx-click="unmonitor_season"
                      phx-value-season-number={season_num}
                      class="btn btn-sm btn-ghost"
                    >
                      <.icon name="hero-bookmark" class="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>

              <SegmentComponents.segment_status_row
                :if={@segment_detection_available}
                season_number={season_num}
                status={Map.get(@segment_statuses, season_num)}
              />

              <%!-- Episodes list --%>
              <div class="bg-base-100 rounded-lg divide-y divide-base-200">
                <%= for episode <- Enum.sort_by(episodes, & &1.episode_number, :desc) do %>
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
                              name={
                                if is_expanded, do: "hero-chevron-down", else: "hero-chevron-right"
                              }
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
                            title={
                              if episode.monitored, do: "Stop monitoring", else: "Start monitoring"
                            }
                          >
                            <.icon
                              name={
                                if episode.monitored, do: "hero-bookmark-solid", else: "hero-bookmark"
                              }
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
                          <.episode_file_row
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
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a single media file row within an expanded episode.
  """
  attr :file, :map, required: true
  attr :episode, :map, required: true
  attr :playback_enabled, :boolean, required: true
  attr :transcode_jobs, :list, default: []

  def episode_file_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 py-1">
      <%!-- File info --%>
      <div class="flex flex-col gap-1 min-w-0 flex-1">
        <%!-- Filename row --%>
        <div class="flex items-center gap-2">
          <.icon name="hero-document" class="w-4 h-4 text-base-content/50 flex-shrink-0" />
          <% absolute_path = Mydia.Library.MediaFile.absolute_path(@file) %>
          <span class="font-mono text-sm truncate" title={absolute_path}>
            {Path.basename(absolute_path)}
          </span>
        </div>
        <%!-- Technical details row --%>
        <div class="flex flex-wrap items-center gap-1.5 pl-6 text-xs">
          <span class="badge badge-primary badge-xs">{@file.resolution || "?"}</span>
          <%= if @file.codec do %>
            <span class="text-base-content/60" title={@file.codec}>
              {shorten_codec(@file.codec)}
            </span>
          <% end %>
          <%= if @file.audio_codec do %>
            <span class="text-base-content/60" title={@file.audio_codec}>
              {shorten_codec(@file.audio_codec)}
            </span>
          <% end %>
          <span class="text-base-content/60">
            {format_file_size(@file.size)}
          </span>
        </div>
      </div>
      <%!-- File actions --%>
      <div class="flex items-center gap-1 flex-shrink-0">
        <% available_resolutions =
          available_transcode_resolutions(
            @file,
            Map.new(@transcode_jobs, fn j -> {j.resolution, j} end)
          ) %>
        <%= if available_resolutions != [] do %>
          <div class="dropdown dropdown-end">
            <div
              tabindex="0"
              role="button"
              class="btn btn-ghost btn-xs btn-square"
              title="Pre-transcode"
            >
              <.icon name="hero-wrench" class="w-4 h-4" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu bg-base-100 rounded-box z-[1] w-44 p-2 shadow"
            >
              <li :for={res <- available_resolutions}>
                <button
                  type="button"
                  phx-click="pre_transcode"
                  phx-value-media-file-id={@file.id}
                  phx-value-resolution={res}
                >
                  {res}
                </button>
              </li>
            </ul>
          </div>
        <% end %>
        <%= if @playback_enabled do %>
          <a
            href={
              flutter_player_url("episode", @episode.id, file_id: @file.id, title: @episode.title)
            }
            class="btn btn-ghost btn-xs btn-square"
            title="Play this file"
          >
            <.icon name="hero-play-solid" class="w-4 h-4" />
          </a>
        <% end %>
        <button
          type="button"
          phx-click="mark_file_preferred"
          phx-value-file-id={@file.id}
          class="btn btn-ghost btn-xs btn-square"
          title="Mark as preferred"
        >
          <.icon name="hero-star" class="w-4 h-4" />
        </button>
        <button
          type="button"
          phx-click="show_file_delete_confirm"
          phx-value-file-id={@file.id}
          class="btn btn-ghost btn-xs btn-square text-error hover:bg-error hover:text-error-content"
          title="Delete file"
        >
          <.icon name="hero-trash" class="w-4 h-4" />
        </button>
      </div>
    </div>
    <%!-- Transcode job badges --%>
    <%= if @transcode_jobs != [] do %>
      <div class="flex flex-wrap items-center gap-2 pl-6 mt-1">
        <.transcode_badge
          :for={job <- @transcode_jobs}
          job={job}
          file={@file}
        />
      </div>
    <% end %>
    """
  end

  # Shorten long codec names for display
  defp shorten_codec(nil), do: nil

  defp shorten_codec(codec) do
    codec
    |> String.replace(~r/\s*\([^)]*\)/, "")
    |> String.replace("Dolby Digital Plus", "DD+")
    |> String.replace("Dolby Digital", "DD")
    |> String.replace("DTS-HD MA", "DTS-MA")
    |> String.replace("TrueHD", "TrueHD")
  end

  @doc """
  Media files section showing all files for this media item.
  """
  attr :media_item, :map, required: true
  attr :refreshing_file_metadata, :boolean, required: true
  attr :transcode_jobs, :map, default: %{}

  def media_files_section(assigns) do
    ~H"""
    <%= if length(@media_item.media_files) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Media Files</h2>
          <%!-- DaisyUI list component --%>
          <ul class="menu bg-base-100 rounded-box p-0">
            <li :for={file <- @media_item.media_files}>
              <div class="flex flex-col gap-3 p-4 hover:bg-base-200 rounded-none transition-colors">
                <div class="flex items-start justify-between gap-4">
                  <%!-- Left side: File info --%>
                  <div class="flex-1 min-w-0 flex flex-col gap-2">
                    <%!-- File path --%>
                    <% absolute_path = Mydia.Library.MediaFile.absolute_path(file) %>
                    <p
                      class="text-sm font-mono text-base-content break-all leading-relaxed"
                      title={absolute_path}
                    >
                      {absolute_path}
                    </p>
                    <%!-- Technical details with quality badge --%>
                    <div class="flex flex-wrap gap-4 text-xs text-base-content/70 items-center">
                      <span class="badge badge-primary badge-sm">
                        {file.resolution || "Unknown"}
                      </span>
                      <div class="flex items-center gap-1.5">
                        <.icon name="hero-film" class="w-3.5 h-3.5" />
                        <span>{file.codec || "Unknown"}</span>
                      </div>
                      <div class="flex items-center gap-1.5">
                        <.icon name="hero-speaker-wave" class="w-3.5 h-3.5" />
                        <span>{file.audio_codec || "Unknown"}</span>
                      </div>
                      <div class="flex items-center gap-1.5">
                        <.icon name="hero-circle-stack" class="w-3.5 h-3.5" />
                        <span class="font-mono">{format_file_size(file.size)}</span>
                      </div>
                    </div>
                  </div>
                  <%!-- Right side: Icon-only action buttons --%>
                  <div class="flex items-center gap-1 flex-shrink-0">
                    <% available_resolutions =
                      available_transcode_resolutions(
                        file,
                        Map.new(Map.get(@transcode_jobs, file.id, []), fn j -> {j.resolution, j} end)
                      ) %>
                    <%= if available_resolutions != [] do %>
                      <div class="dropdown dropdown-end">
                        <div
                          tabindex="0"
                          role="button"
                          class="btn btn-ghost btn-sm btn-square"
                          title="Pre-transcode"
                        >
                          <.icon name="hero-wrench" class="w-5 h-5" />
                        </div>
                        <ul
                          tabindex="0"
                          class="dropdown-content menu bg-base-100 rounded-box z-[1] w-44 p-2 shadow"
                        >
                          <li :for={res <- available_resolutions}>
                            <button
                              type="button"
                              phx-click="pre_transcode"
                              phx-value-media-file-id={file.id}
                              phx-value-resolution={res}
                            >
                              {res}
                            </button>
                          </li>
                        </ul>
                      </div>
                    <% end %>
                    <button
                      type="button"
                      phx-click="show_file_details"
                      phx-value-file-id={file.id}
                      class="btn btn-ghost btn-sm btn-square"
                      aria-label="View file details"
                      title="View file details"
                    >
                      <.icon name="hero-information-circle" class="w-5 h-5" />
                    </button>
                    <button
                      type="button"
                      phx-click="mark_file_preferred"
                      phx-value-file-id={file.id}
                      class="btn btn-ghost btn-sm btn-square"
                      aria-label="Mark this file as preferred"
                      title="Mark as preferred"
                    >
                      <.icon name="hero-star" class="w-5 h-5" />
                    </button>
                    <button
                      type="button"
                      phx-click="show_file_delete_confirm"
                      phx-value-file-id={file.id}
                      class="btn btn-ghost btn-sm btn-square text-error hover:bg-error hover:text-error-content"
                      aria-label="Delete this file"
                      title="Delete file"
                    >
                      <.icon name="hero-trash" class="w-5 h-5" />
                    </button>
                  </div>
                </div>
                <%!-- Pre-transcode status and controls --%>
                <.transcode_controls
                  file={file}
                  transcode_jobs={Map.get(@transcode_jobs, file.id, [])}
                />
              </div>
            </li>
          </ul>
        </div>
      </div>
    <% end %>
    """
  end

  attr :file, :map, required: true
  attr :transcode_jobs, :list, default: []

  defp transcode_controls(assigns) do
    ~H"""
    <%= if @transcode_jobs != [] do %>
      <div class="flex flex-wrap items-center gap-2">
        <.transcode_badge
          :for={job <- @transcode_jobs}
          job={job}
          file={@file}
        />
      </div>
    <% end %>
    """
  end

  attr :job, :map, required: true
  attr :file, :map, required: true

  defp transcode_badge(assigns) do
    ~H"""
    <div class={[
      "badge badge-sm gap-1",
      transcode_badge_class(@job.status)
    ]}>
      <%= case @job.status do %>
        <% "ready" -> %>
          <.icon name="hero-check-circle-mini" class="w-3 h-3" />
          {@job.resolution}
        <% "transcoding" -> %>
          <span class="loading loading-spinner loading-xs"></span>
          {@job.resolution} {format_transcode_progress(@job.progress)}
        <% "pending" -> %>
          <.icon name="hero-clock" class="w-3 h-3" />
          {@job.resolution} queued
        <% "failed" -> %>
          <.icon name="hero-exclamation-triangle-mini" class="w-3 h-3" />
          {@job.resolution} failed
        <% _other -> %>
          {@job.resolution}
      <% end %>
      <%= if @job.status in ["pending", "transcoding"] do %>
        <button
          type="button"
          phx-click="cancel_transcode"
          phx-value-job-id={@job.id}
          class="ml-1 hover:text-error"
          title="Cancel transcode"
        >
          <.icon name="hero-x-mark-mini" class="w-3 h-3" />
        </button>
      <% end %>
    </div>
    """
  end

  defp transcode_badge_class("ready"), do: "badge-success"
  defp transcode_badge_class("transcoding"), do: "badge-warning"
  defp transcode_badge_class("pending"), do: "badge-info"
  defp transcode_badge_class("failed"), do: "badge-error"
  defp transcode_badge_class(_), do: "badge-ghost"

  defp format_transcode_progress(nil), do: ""

  defp format_transcode_progress(progress) when is_float(progress) do
    "#{round(progress * 100)}%"
  end

  defp format_transcode_progress(_), do: ""

  defp available_transcode_resolutions(file, jobs_by_resolution) do
    source_height = Mydia.Downloads.DownloadService.parse_resolution_height(file.resolution)

    [{"1080p", 1080}, {"720p", 720}, {"480p", 480}]
    |> Enum.filter(fn {_res, height} -> height <= source_height end)
    |> Enum.reject(fn {res, _height} -> Map.has_key?(jobs_by_resolution, res) end)
    |> Enum.map(fn {res, _height} -> res end)
  end

  @doc """
  Timeline section showing history of events.
  """
  attr :timeline_events, :list, required: true

  def timeline_section(assigns) do
    ~H"""
    <%= if length(@timeline_events) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">History</h2>
          <%!-- Horizontal scrollable timeline container --%>
          <div class="w-full overflow-x-auto scroll-smooth pb-4 -mx-4 px-4">
            <div class="flex gap-0 min-w-max relative">
              <%!-- Horizontal timeline line --%>
              <div class="absolute top-[32px] left-0 right-0 h-0.5 bg-base-300 z-0"></div>

              <%!-- Timeline events --%>
              <%= for {event, index} <- Enum.with_index(@timeline_events) do %>
                <div class="relative flex flex-col items-center z-10 min-w-[280px] md:min-w-[280px]">
                  <%!-- Time above timeline --%>
                  <time
                    class="text-xs text-base-content/60 mb-2 whitespace-nowrap"
                    title={format_absolute_time(event.timestamp)}
                  >
                    {format_relative_time(event.timestamp)}
                  </time>

                  <%!-- Timeline node and connector --%>
                  <div class="relative flex items-center justify-center">
                    <%!-- Icon node on timeline --%>
                    <div class="w-10 h-10 rounded-full bg-base-200 flex items-center justify-center border-2 border-base-300 z-20">
                      <.icon name={event.icon} class={"w-5 h-5 #{event.color}"} />
                    </div>
                  </div>

                  <%!-- Event card below timeline --%>
                  <div
                    class="card bg-base-100 shadow-md mt-4 w-64 md:w-64 hover:shadow-xl transition-shadow"
                    title={format_absolute_time(event.timestamp)}
                  >
                    <div class="card-body p-4">
                      <div class="font-bold text-sm mb-2">{event.title}</div>
                      <div class="text-sm text-base-content/80 mb-2 line-clamp-2">
                        {event.description}
                      </div>
                      <%= if event.metadata do %>
                        <div class="flex flex-wrap gap-1">
                          <%= if event.metadata[:quality] do %>
                            <span class="badge badge-primary badge-xs">
                              {format_download_quality(event.metadata.quality)}
                            </span>
                          <% end %>
                          <%= if event.metadata[:indexer] do %>
                            <span class="badge badge-outline badge-xs">
                              {event.metadata.indexer}
                            </span>
                          <% end %>
                          <%= if event.metadata[:resolution] do %>
                            <span class="badge badge-primary badge-xs">
                              {event.metadata.resolution}
                            </span>
                          <% end %>
                          <%= if event.metadata[:size] do %>
                            <span class="badge badge-ghost badge-xs">
                              {format_file_size(event.metadata.size)}
                            </span>
                          <% end %>
                          <%= if event.metadata[:error] do %>
                            <div class="text-xs text-error mt-1 line-clamp-2">
                              <.icon name="hero-exclamation-circle" class="w-3 h-3 inline" />
                              {event.metadata.error}
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Connecting line to next event --%>
                  <%= if index < length(@timeline_events) - 1 do %>
                    <div class={"absolute top-[32px] left-1/2 w-[280px] h-0.5 #{event.color} z-0"}>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Subtitles section showing available and downloaded subtitles for media files.
  """
  attr :media_item, :map, required: true
  attr :subtitle_feature_enabled, :boolean, required: true
  attr :media_file_subtitles, :map, default: %{}

  def subtitles_section(assigns) do
    ~H"""
    <%= if @subtitle_feature_enabled && length(@media_item.media_files) > 0 do %>
      <div class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Subtitles</h2>

          <%!-- Media files with subtitle controls --%>
          <div class="space-y-4">
            <%= for media_file <- @media_item.media_files do %>
              <% file_subtitles = Map.get(@media_file_subtitles, media_file.id, []) %>
              <div class="card bg-base-100 shadow">
                <div class="card-body p-4">
                  <%!-- File info header --%>
                  <div class="flex items-start justify-between gap-4 mb-3">
                    <div class="flex-1 min-w-0">
                      <% absolute_path = Mydia.Library.MediaFile.absolute_path(media_file) %>
                      <p
                        class="text-sm font-mono text-base-content/80 break-all"
                        title={absolute_path}
                      >
                        {Path.basename(absolute_path)}
                      </p>
                      <div class="flex gap-2 mt-1">
                        <span class="badge badge-primary badge-xs">
                          {media_file.resolution || "Unknown"}
                        </span>
                        <span class="badge badge-ghost badge-xs">
                          {media_file.codec || "Unknown"}
                        </span>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="open_subtitle_search"
                      phx-value-media-file-id={media_file.id}
                      class="btn btn-primary btn-sm"
                    >
                      <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Search
                    </button>
                  </div>

                  <%!-- Downloaded subtitles --%>
                  <%= if length(file_subtitles) > 0 do %>
                    <div class="divider my-2">Downloaded Subtitles</div>
                    <ul class="space-y-2">
                      <%= for subtitle <- file_subtitles do %>
                        <li class="flex items-center justify-between gap-2 p-2 bg-base-200 rounded">
                          <div class="flex items-center gap-2 flex-1">
                            <span class="badge badge-outline badge-sm">{subtitle.language}</span>
                            <span class="text-sm">{subtitle.format}</span>
                            <%= if subtitle.rating do %>
                              <div class="flex items-center gap-1">
                                <.icon name="hero-star-solid" class="w-3 h-3 text-warning" />
                                <span class="text-xs">{subtitle.rating}/10</span>
                              </div>
                            <% end %>
                          </div>
                          <button
                            type="button"
                            phx-click="delete_subtitle"
                            phx-value-subtitle-id={subtitle.id}
                            class="btn btn-ghost btn-xs btn-square text-error"
                            title="Delete subtitle"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        </li>
                      <% end %>
                    </ul>
                  <% else %>
                    <p class="text-sm text-base-content/60 italic">
                      No subtitles downloaded yet
                    </p>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # Helper functions for monitoring preset labels

  # monitoring_preset_label/1 is provided by MydiaWeb.MediaLive.Show.Helpers (imported above)

  @doc """
  Monitoring icon that shows different states:
  - All: solid bookmark (fully monitored)
  - None: outline bookmark (not monitored)
  - Partial presets: half-filled bookmark effect
  """
  attr :preset, :atom, required: true
  attr :class, :string, default: "w-5 h-5"

  def monitoring_icon(%{preset: preset} = assigns) when preset in [nil, :all] do
    ~H"""
    <.icon name="hero-bookmark-solid" class={@class} />
    """
  end

  def monitoring_icon(%{preset: :none} = assigns) do
    ~H"""
    <.icon name="hero-bookmark" class={@class} />
    """
  end

  def monitoring_icon(assigns) do
    # Partial monitoring: show a half-filled effect using stacked icons
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
