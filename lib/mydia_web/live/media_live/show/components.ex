defmodule MydiaWeb.MediaLive.Show.Components do
  @moduledoc """
  UI component sections for the MediaLive.Show page.
  """
  use MydiaWeb, :html
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.MediaLive.Show.Helpers

  alias MydiaWeb.MediaLive.Show.LibraryComponents
  alias MydiaWeb.MediaLive.Show.SegmentComponents
  alias MydiaWeb.MediaLive.Show.SeasonComponents
  alias MydiaWeb.MediaLive.Show.SeasonOrderComponents
  alias MydiaWeb.MediaLive.Show.SubtitleComponents

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
  attr :target_library, :map, default: nil
  attr :target_reason, :atom, default: nil
  attr :target_library_candidates, :list, default: []
  attr :is_favorite, :boolean, default: false
  attr :item_collections, :list, default: []
  attr :user_collections, :list, default: []

  # Labels only. The list of valid presets is Media.monitoring_presets/0, and
  # this is checked against it at compile time so the two cannot drift.
  @preset_labels %{
    all: "All Episodes",
    missing: "Missing Episodes",
    existing: "Existing Episodes",
    future: "Future Episodes",
    none: "No Episodes"
  }

  @monitoring_presets Enum.map(
                        Mydia.Media.monitoring_presets(),
                        &{&1, Map.fetch!(@preset_labels, &1)}
                      )

  def hero_section(assigns) do
    ~H"""
    <%!-- Left Column: Poster and Quick Actions --%>
    <%!-- self-start is load-bearing. Without it this grid item stretches to the
          full row height, position: sticky has no travel room inside its own
          box, and the column silently does not pin.

          The inner scroll is not optional either. The column runs roughly
          830px at lg (a 320px poster at 2:3 is 480px, plus about 350px of
          actions and info cards), which is taller than most laptop viewports.
          Plain sticky on a taller-than-viewport element makes its bottom
          permanently unreachable, so the Target Library and Path rows would
          never be visible.

          The top offset is NOT a flat top-4 across the whole md+ range.
          `Layouts.app/1` renders a `lg:hidden sticky top-0 z-30` mobile
          header, visible from 0 up to just under lg (1024px) - the entire md
          band this column starts pinning in. Two siblings sharing the page's
          scroll context both being sticky means whichever pins lower in the
          DOM and has no z-index (this column; z-index: auto) paints under
          the one that does (the header; z-30) wherever their boxes overlap.
          Measured on the running page at 900px wide: with both pinned, the
          header (0-64px) and the column (16-769px) overlap by 48px, and
          elementFromPoint over that band hits the header, not the column -
          the column's top ~48px (through the top of the poster card) is
          genuinely covered while scrolled. So below lg the column pins
          beneath the header's 64px instead of at top-4, and max-h shrinks by
          the same amount so the bottom stays reachable inside the viewport;
          at lg the header is gone and both revert to the plain top-4. --%>
    <div class="md:sticky md:self-start md:overflow-y-auto md:top-20 md:max-h-[calc(100vh-6rem)] lg:top-4 lg:max-h-[calc(100vh-2rem)]">
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
            id="manual-search-button"
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

          <%!-- Opens a page-level modal (Modals.add_to_collection_modal/1) rather
                than an anchored dropdown, because this button lives inside the
                hero column's overflow-y-auto wrapper (see the note at the top
                of this function), which clips a `.dropdown-content` menu the
                moment its content is taller than the column's remaining
                headroom. Confirmed by measuring the real page: see the
                UI polish fix wave report. --%>
          <button
            type="button"
            phx-click="open_add_to_collection_modal"
            class="btn btn-outline w-full"
          >
            <.icon name="hero-folder-plus" class="w-5 h-5" />
            <span class="hidden sm:inline">Collection</span>
          </button>
        </div>

        <%!-- Secondary actions --%>
        <div class="flex flex-col gap-2">
          <%!-- Show-level on/off only. The bulk episode actions live in the
                Seasons & Episodes header, next to what they act on. --%>
          <%= if @media_item.type == "tv_show" do %>
            <.monitored_toggle id="show-monitored-toggle" media_item={@media_item} />
          <% else %>
            <.monitored_toggle id="movie-monitored-toggle" media_item={@media_item} />
          <% end %>
        </div>

        <%!-- Info Cards --%>
        <div class="rounded-box bg-base-200/50 p-2 space-y-1 mt-3">
          <%!-- Quality Profile. A button opening a page-level modal
                (Modals.quality_profile_modal/1) rather than an anchored
                dropdown, for the same reason as the Collection button above:
                the hero column's overflow-y-auto wrapper clips a
                `.dropdown-content` list once it runs past the column's
                remaining headroom, which a real quality-profile list (a
                handful of profiles) reliably does. Measured, not assumed:
                see the UI polish fix wave report. --%>
          <button
            type="button"
            phx-click="show_quality_profile_modal"
            class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg cursor-pointer hover:bg-base-300/50 transition-colors w-full group"
            title="Click to change quality profile"
          >
            <div class="w-8 h-8 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0">
              <.icon name="hero-adjustments-horizontal" class="w-4 h-4 text-primary" />
            </div>
            <div class="flex-1 min-w-0 text-left">
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
          </button>

          <LibraryComponents.target_library_row
            media_item={@media_item}
            target_library={@target_library}
            target_reason={@target_reason}
            libraries={@target_library_candidates}
          />

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
  Episodes section for TV shows. Each season is a disclosure, delegated to
  `SeasonComponents.season_section/1`.
  """
  attr :media_item, :map, required: true
  attr :expanded_seasons, :any, required: true
  attr :expanded_episodes, :map, default: MapSet.new()
  attr :expanded_chunks, :any, default: MapSet.new()
  attr :auto_searching_season, :any, default: nil
  attr :rescanning_season, :any, default: nil
  attr :fetching_season_subtitles, :any, default: nil
  attr :auto_searching_episode, :any, default: nil
  attr :playback_enabled, :boolean, required: true
  attr :transcode_jobs, :map, default: %{}
  attr :media_file_subtitle_tracks, :map, default: %{}
  attr :segment_statuses, :map, default: %{}
  attr :segment_detection_available, :boolean, default: true
  attr :season_order_suggestion, :any, default: nil
  attr :season_order_options, :any, default: nil
  attr :can_update_media, :boolean, required: true

  def episodes_section(assigns) do
    assigns = assign(assigns, :monitoring_presets, @monitoring_presets)

    ~H"""
    <%= if @media_item.type == "tv_show" && length(@media_item.episodes) > 0 do %>
      <% grouped_seasons = group_episodes_by_season(@media_item.episodes)
      derived_preset = Mydia.Media.derive_monitoring_preset(@media_item.episodes) %>

      <div id="seasons-episodes-section" class="card bg-base-200 shadow-lg">
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

              <%!-- Standing rule, not an action. Independent of the presets
                    on purpose: "everything I have, but do not chase new
                    seasons" is a real thing to want, and inferring this from
                    the preset made it unsayable. --%>
              <label
                class="flex items-center gap-1.5 cursor-pointer text-base-content/70"
                title="Whether a season added later arrives monitored. Episodes added to a season you already have follow that season instead."
              >
                <input
                  type="checkbox"
                  id="monitor-new-seasons-toggle"
                  class="checkbox checkbox-xs"
                  checked={@media_item.monitor_new_seasons == :all}
                  phx-click="toggle_monitor_new_seasons"
                />
                <span>New seasons</span>
              </label>

              <%!-- One-shot bulk actions. The label reads the episode rows
                    back rather than storing what was picked, so a manual
                    season toggle shows as Custom instead of going stale. --%>
              <div class="dropdown dropdown-end">
                <div
                  tabindex="0"
                  role="button"
                  id="episode-monitoring-menu"
                  class="btn btn-sm btn-ghost gap-1"
                >
                  <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
                  <span>{monitoring_preset_label(derived_preset)}</span>
                  <.icon name="hero-chevron-down" class="w-3 h-3 opacity-70" />
                </div>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-56 border border-base-300"
                >
                  <li :for={{preset, label} <- @monitoring_presets}>
                    <button
                      type="button"
                      id={"episode-monitoring-menu-preset-#{preset}"}
                      phx-click="apply_episode_monitoring"
                      phx-value-preset={preset}
                    >
                      {label}
                    </button>
                  </li>
                </ul>
              </div>
            </div>
          </div>
          <SegmentComponents.segment_unavailable_note :if={!@segment_detection_available} />
        </div>

        <div class="card-body p-4 pb-0 pt-0">
          <SeasonOrderComponents.season_order_controls
            media_item={@media_item}
            season_order_suggestion={@season_order_suggestion}
            options={@season_order_options}
            can_update_media={@can_update_media}
          />
        </div>

        <%!-- All seasons in one container --%>
        <div class="divide-y divide-base-300">
          <%= for {season_num, episodes} <- grouped_seasons do %>
            <SeasonComponents.season_section
              season_number={season_num}
              episodes={episodes}
              expanded?={MapSet.member?(@expanded_seasons, season_num)}
              expanded_episodes={@expanded_episodes}
              expanded_chunks={@expanded_chunks}
              auto_searching_season={@auto_searching_season}
              rescanning_season={@rescanning_season}
              fetching_season_subtitles={@fetching_season_subtitles}
              auto_searching_episode={@auto_searching_episode}
              playback_enabled={@playback_enabled}
              transcode_jobs={@transcode_jobs}
              media_file_subtitle_tracks={@media_file_subtitle_tracks}
              segment_statuses={@segment_statuses}
              segment_detection_available={@segment_detection_available}
            />
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
  attr :subtitle_tracks, :list, default: []

  def episode_file_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 py-1">
      <%!-- File info --%>
      <div class="flex flex-col gap-1 min-w-0 flex-1">
        <%!-- Filename row --%>
        <div class="flex items-center gap-2">
          <.icon name="hero-document" class="w-4 h-4 text-base-content/50 flex-shrink-0" />
          <span
            class="font-mono text-sm truncate"
            title={Mydia.Library.MediaFile.display_path(@file)}
          >
            {Mydia.Library.MediaFile.display_name(@file)}
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
        <SubtitleComponents.subtitle_badges
          :if={@subtitle_tracks != []}
          tracks={@subtitle_tracks}
          id={@file.id}
        />
      </div>
      <%!-- File actions --%>
      <div class="flex items-center gap-1 flex-shrink-0">
        <button
          id={"subtitle-open-#{@file.id}"}
          type="button"
          phx-click="open_subtitle_manage"
          phx-value-media-file-id={@file.id}
          class="btn btn-ghost btn-xs btn-square"
          aria-label="Manage subtitles"
          title="Subtitles"
        >
          <.icon name="hero-language" class="w-4 h-4" />
        </button>
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
  Media files section, showing the files that belong to this item directly and
  to no episode.

  For a movie that is simply its files. For a TV show it is the files with
  `media_item_id` set and `episode_id` nil, which `Mydia.Jobs.MediaImport`'s
  catch-all fallback creates when a download's episode cannot be resolved and
  `Mydia.Media.RecentlyAdded` documents as "unmatched files". No episode row
  will ever render those, so this card is their only surface -- hence the
  filter on `episode_id` rather than skipping the card for shows outright.

  It deliberately does *not* list a show's episode files, even though
  `all_media_files/1` reaches them. `episode_rows/1` already renders each of
  those under its own episode, with the season and episode number attached.
  Listing them again here produced a flat, unlabelled pile under a heading
  that reads as show-level: on the reference deployment, 49 of 53 shows with
  files rendered a card that was 100% episode files (Silo: 29 rows, every one
  a duplicate of something already shown above). That is what the merged list
  looked like in practice, and it read as detached files rather than as a
  useful overview.

  Because the two surfaces are now disjoint, no file can render twice on the
  page. The `-file-` DOM id suffix here (`subtitle-open-file-<id>`,
  `subtitle-badges-file-<id>`) is kept anyway, distinct from
  `episode_file_row/1`'s plain `subtitle-open-<id>` / `subtitle-badges-<id>`,
  so a future change that widens either list cannot silently reintroduce a
  duplicate-id crash.

  Note the other four call sites fixed alongside this one in #591 -- the
  quality filter and badge, the list view's Size column, and
  `FileEvents.refresh_all_file_metadata/2` -- do still want the merged list
  from `all_media_files/1`. They answer questions about the whole show; this
  card does not.
  """
  attr :media_item, :map, required: true
  attr :refreshing_file_metadata, :boolean, required: true
  attr :transcode_jobs, :map, default: %{}
  attr :media_file_subtitle_tracks, :map, default: %{}

  def media_files_section(assigns) do
    files = Enum.filter(all_media_files(assigns.media_item), &is_nil(&1.episode_id))
    {extras, versions} = Enum.split_with(files, &(not is_nil(&1.extra_kind)))

    assigns = assign(assigns, files: files, versions: versions, extras: extras)

    ~H"""
    <%= if @files != [] do %>
      <div id="media-files-section" class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">Media Files</h2>
          <%!-- DaisyUI list component --%>
          <ul class="menu bg-base-100 rounded-box p-0">
            <li :for={file <- @versions} id={"version-#{file.id}"}>
              <div class="flex flex-col gap-3 p-4 hover:bg-base-200 rounded-none transition-colors">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
                  <%!-- Left side: File info --%>
                  <div class="min-w-0 sm:flex-1 flex flex-col gap-2">
                    <%!-- File name. The full path lives on the title attribute
                          and in the file details modal. Rendered here it left
                          about 90px of column beside the button strip on a
                          375px phone, and break-all shredded it into a tall
                          narrow stack of characters rather than clipping. --%>
                    <% file_path = Mydia.Library.MediaFile.display_path(file) %>
                    <p
                      id={"file-name-#{file.id}"}
                      class="text-sm font-mono text-base-content truncate leading-relaxed"
                      title={file_path}
                    >
                      <%!-- display_name/1 is the "Unknown file" label when there is no path,
                            so an orphaned row reads the same here as everywhere else. --%>
                      {Mydia.Library.MediaFile.display_name(file)}
                    </p>
                    <%!-- Technical details with quality badge. gap-x-3 rather
                          than gap-4: four short badges do not need 16px of
                          separation, and on a phone that gap forces a ragged
                          wrap. Codec names run through shorten_codec/1, the
                          same helper episode_file_row/1 uses. --%>
                    <div
                      id={"file-meta-#{file.id}"}
                      class="flex flex-wrap gap-x-3 gap-y-1.5 text-xs text-base-content/70 items-center"
                    >
                      <span class="badge badge-primary badge-sm">
                        {file.resolution || "Unknown"}
                      </span>
                      <div class="flex items-center gap-1.5">
                        <.icon name="hero-film" class="w-3.5 h-3.5" />
                        <span title={file.codec}>{shorten_codec(file.codec) || "Unknown"}</span>
                      </div>
                      <div class="flex items-center gap-1.5">
                        <.icon name="hero-speaker-wave" class="w-3.5 h-3.5" />
                        <span title={file.audio_codec}>
                          {shorten_codec(file.audio_codec) || "Unknown"}
                        </span>
                      </div>
                      <div class="flex items-center gap-1.5">
                        <.icon name="hero-circle-stack" class="w-3.5 h-3.5" />
                        <span class="font-mono">{format_file_size(file.size)}</span>
                      </div>
                    </div>
                    <SubtitleComponents.subtitle_badges
                      :if={Map.get(@media_file_subtitle_tracks, file.id, []) != []}
                      tracks={Map.get(@media_file_subtitle_tracks, file.id, [])}
                      id={"file-#{file.id}"}
                    />
                  </div>
                  <%!-- Right side: Icon-only action buttons --%>
                  <div class="flex items-center justify-end gap-1 flex-shrink-0">
                    <button
                      id={"subtitle-open-file-#{file.id}"}
                      type="button"
                      phx-click="open_subtitle_manage"
                      phx-value-media-file-id={file.id}
                      class="btn btn-ghost btn-square sm:btn-sm"
                      aria-label="Manage subtitles"
                      title="Subtitles"
                    >
                      <.icon name="hero-language" class="w-5 h-5" />
                    </button>
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
                          class="btn btn-ghost btn-square sm:btn-sm"
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
                      class="btn btn-ghost btn-square sm:btn-sm"
                      aria-label="View file details"
                      title="View file details"
                    >
                      <.icon name="hero-information-circle" class="w-5 h-5" />
                    </button>
                    <button
                      type="button"
                      phx-click="mark_file_preferred"
                      phx-value-file-id={file.id}
                      class="btn btn-ghost btn-square sm:btn-sm"
                      aria-label="Mark this file as preferred"
                      title="Mark as preferred"
                    >
                      <.icon name="hero-star" class="w-5 h-5" />
                    </button>
                    <button
                      type="button"
                      phx-click="show_file_delete_confirm"
                      phx-value-file-id={file.id}
                      class="btn btn-ghost btn-square sm:btn-sm text-error hover:bg-error hover:text-error-content"
                      aria-label="Delete this file"
                      title="Delete file"
                    >
                      <.icon name="hero-trash" class="w-5 h-5" />
                    </button>
                    <button
                      id={"demote-#{file.id}"}
                      type="button"
                      class="btn btn-ghost btn-square sm:btn-sm"
                      title="This is an extra, not a version"
                      phx-click="demote_to_extra"
                      phx-value-id={file.id}
                    >
                      <.icon name="hero-arrow-down-tray" class="w-5 h-5" />
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

          <details :if={@extras != []} id="extras-disclosure" class="mt-4">
            <summary class="cursor-pointer text-sm font-medium text-base-content/70 hover:text-base-content">
              Extras ({length(@extras)})
            </summary>
            <ul class="menu bg-base-100 rounded-box p-0 mt-2">
              <li :for={file <- @extras} id={"extra-#{file.id}"}>
                <div class="flex items-center justify-between gap-4 p-4 rounded-none">
                  <div class="flex-1 min-w-0 flex flex-col gap-1">
                    <p class="text-sm font-mono break-all">
                      {Mydia.Library.MediaFile.display_path(file) ||
                        Mydia.Library.MediaFile.display_name(file)}
                    </p>
                    <div class="flex flex-wrap gap-2 text-xs text-base-content/60">
                      <span class="badge badge-ghost badge-sm">{file.extra_kind}</span>
                      <span class="badge badge-ghost badge-sm">
                        detected by {file.extra_source}
                      </span>
                      <span class="font-mono">{format_file_size(file.size)}</span>
                    </div>
                  </div>
                  <button
                    id={"promote-#{file.id}"}
                    type="button"
                    class="btn btn-ghost btn-sm"
                    title="This is a version, not an extra"
                    phx-click="promote_to_version"
                    phx-value-id={file.id}
                  >
                    <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Version
                  </button>
                </div>
              </li>
            </ul>
          </details>
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

  Vertical, and positioned by the page grid rather than by its place in the
  main column: past the grid's container-query threshold it is the third
  column, and below it falls to a full-width row under the other two. See
  show.html.heex for the grid.

  It renders nothing at all on an item with no events, which is why the page
  grid picks its column template from `@timeline_events != []`.

  Collapsed, it renders at most five events. That cap is load-bearing rather
  than cosmetic: `position: sticky` only pins usefully on an element shorter
  than the viewport, and the rail used to be `max-h-[calc(100vh-2rem)]` with
  an inner `overflow-y-auto` over as many as 50 events. Measured on the
  shipped layout, its top offset ran 64 at rest, 0 mid-scroll and -48 at the
  page bottom, so the heading scrolled off the top and never held. Five dense
  rows measure 506px, which fits a 768px-tall laptop.

  Expanded, it renders everything it was given, and show.html.heex drops the
  `sticky` classes, because a taller-than-viewport sticky element has a
  permanently unreachable bottom.
  """
  @timeline_visible_count 5

  attr :timeline_events, :list, required: true
  attr :expanded, :boolean, default: false

  def timeline_section(assigns) do
    assigns =
      assigns
      |> assign(
        :shown_events,
        if(assigns.expanded,
          do: assigns.timeline_events,
          else: Enum.take(assigns.timeline_events, @timeline_visible_count)
        )
      )
      |> assign(
        :hidden_count,
        max(length(assigns.timeline_events) - @timeline_visible_count, 0)
      )

    ~H"""
    <%= if length(@timeline_events) > 0 do %>
      <div id="timeline-section" class="card bg-base-200 shadow-lg mb-4 md:mb-6">
        <div class="card-body p-4 md:p-6">
          <h2 class="card-title text-lg md:text-xl mb-3 md:mb-4">History</h2>
          <div class="relative">
            <%!-- The spine. Inset to the centre of the 32px icon nodes below
                  (left-4 is 16px), so every node sits on it. --%>
            <div class="absolute left-4 top-0 bottom-0 w-0.5 bg-base-300"></div>

            <div class="flex flex-col gap-3">
              <div
                :for={event <- @shown_events}
                class="relative flex items-start gap-3"
              >
                <%!-- Icon node on the spine --%>
                <div class="w-8 h-8 rounded-full bg-base-200 flex items-center justify-center border-2 border-base-300 shrink-0 z-10">
                  <.icon name={event.icon} class={"w-4 h-4 #{event.color}"} />
                </div>

                <%!-- Flat row rather than a nested card. Title and time share
                      one baseline, both single-line, so the row height is
                      driven by content and not by card padding. --%>
                <div class="flex-1 min-w-0 pt-0.5">
                  <div class="flex items-baseline justify-between gap-2">
                    <span class="font-semibold text-sm truncate" title={event.title}>{event.title}</span>
                    <time
                      class="text-xs text-base-content/50 whitespace-nowrap shrink-0"
                      title={format_absolute_time(event.timestamp)}
                    >
                      {format_relative_time_short(event.timestamp)}
                    </time>
                  </div>
                  <div class="text-xs text-base-content/70 truncate" title={event.description}>
                    {event.description}
                  </div>
                  <%= if event.metadata do %>
                    <div class="flex flex-wrap gap-1 mt-1">
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
                      <%!-- w-full so the error takes its own line inside the
                            wrapping badge row rather than being squeezed into
                            the last badge's slot. --%>
                      <%= if event.metadata[:error] do %>
                        <div class="text-xs text-error mt-1 line-clamp-2 w-full">
                          <.icon name="hero-exclamation-circle" class="w-3 h-3 inline" />
                          {event.metadata.error}
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <button
            :if={@hidden_count > 0}
            id="timeline-toggle"
            type="button"
            phx-click="toggle_timeline"
            aria-expanded={@expanded}
            class="btn btn-ghost btn-sm justify-start self-start mt-2 -mb-1"
          >
            {if @expanded, do: "Show less", else: "Show #{@hidden_count} more"}
          </button>
        </div>
      </div>
    <% end %>
    """
  end

  # Helper functions for monitoring preset labels

  # monitoring_preset_label/1 is provided by MydiaWeb.MediaLive.Show.Helpers (imported above)

  attr :id, :string, required: true
  attr :media_item, :map, required: true

  def monitored_toggle(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
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
      <span>{if @media_item.monitored, do: "Monitored", else: "Not Monitored"}</span>
    </button>
    """
  end
end
