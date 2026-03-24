defmodule MydiaWeb.ImportMediaLive.Components do
  @moduledoc """
  Reusable UI components for the Import Media workflow.

  These components break down the import media interface into smaller,
  focused, and testable pieces. Each component is a pure presentation
  function with clearly defined attributes.
  """

  use Phoenix.Component
  import MydiaWeb.CoreComponents
  alias Mydia.Metadata.ImageUrl

  @doc """
  Renders the progress steps indicator for the import wizard.

  ## Attributes
    * `:step` - Current step (one of: `:select_path`, `:review`, `:importing`, `:complete`)
  """
  attr :step, :atom, required: true

  def progress_steps(assigns) do
    ~H"""
    <ul class="steps steps-horizontal w-full text-xs">
      <li class={"step step-sm " <> if(@step in [:select_path, :review, :importing, :complete], do: "step-primary", else: "")}>
        Select Path
      </li>
      <li class={"step step-sm " <> if(@step in [:review, :importing, :complete], do: "step-primary", else: "")}>
        Review Matches
      </li>
      <li class={"step step-sm " <> if(@step in [:importing, :complete], do: "step-primary", else: "")}>
        Import
      </li>
      <li class={"step step-sm " <> if(@step == :complete, do: "step-primary", else: "")}>
        Complete
      </li>
    </ul>
    """
  end

  @doc """
  Renders the path selection screen where users choose a directory to scan.

  ## Attributes
    * `:library_paths` - List of available library paths
  """
  attr :library_paths, :list, default: []

  def path_selection_screen(assigns) do
    ~H"""
    <div class="flex flex-col items-center">
      <%!-- Hero Section --%>
      <div class="text-center mb-8">
        <div class="inline-flex items-center justify-center w-16 h-16 rounded-full bg-primary/10 mb-4">
          <.icon name="hero-folder-open" class="w-8 h-8 text-primary" />
        </div>
        <h2 class="text-xl font-bold mb-2">Select a Library to Scan</h2>
        <p class="text-sm text-base-content/60 max-w-md">
          Choose one of your configured library paths to discover and import media files.
        </p>
      </div>

      <%!-- Library Paths Grid --%>
      <%= if @library_paths != [] do %>
        <div class="grid gap-3 w-full max-w-2xl">
          <%= for path <- @library_paths do %>
            <button
              type="button"
              class="group card card-compact bg-base-100 border border-base-300 hover:border-primary hover:shadow-lg transition-all duration-200 cursor-pointer text-left"
              phx-click="select_library_path"
              phx-value-path_id={path.id}
            >
              <div class="card-body flex-row items-center gap-4">
                <%!-- Icon based on library type --%>
                <div class={[
                  "flex items-center justify-center w-12 h-12 rounded-lg transition-colors",
                  library_type_bg_class(path.type),
                  "group-hover:scale-105 transition-transform"
                ]}>
                  <.icon name={library_type_icon(path.type)} class="w-6 h-6" />
                </div>

                <%!-- Path info --%>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 mb-1">
                    <span class={[
                      "badge badge-sm",
                      library_type_badge_class(path.type)
                    ]}>
                      {library_type_display(path.type)}
                    </span>
                  </div>
                  <p class="font-mono text-sm truncate text-base-content/80 group-hover:text-base-content">
                    {path.path}
                  </p>
                </div>

                <%!-- Arrow indicator --%>
                <div class="text-base-content/30 group-hover:text-primary group-hover:translate-x-1 transition-all">
                  <.icon name="hero-chevron-right" class="w-5 h-5" />
                </div>
              </div>
            </button>
          <% end %>
        </div>

        <%!-- Hint --%>
        <p class="text-xs text-base-content/50 mt-6 text-center">
          <.icon name="hero-information-circle" class="w-4 h-4 inline -mt-0.5" />
          Need to add more paths? Configure them in
          <a href="/settings/library" class="link link-primary">Library Settings</a>
        </p>
      <% else %>
        <%!-- Empty State --%>
        <div class="card bg-base-200/50 border border-dashed border-base-300 w-full max-w-md">
          <div class="card-body items-center text-center py-12">
            <div class="w-16 h-16 rounded-full bg-warning/10 flex items-center justify-center mb-4">
              <.icon name="hero-folder-plus" class="w-8 h-8 text-warning" />
            </div>
            <h3 class="font-semibold text-lg mb-2">No Library Paths Configured</h3>
            <p class="text-sm text-base-content/60 mb-4">
              Add a library path in Settings to start importing your media files.
            </p>
            <a href="/settings/library" class="btn btn-primary btn-sm gap-2">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> Go to Settings
            </a>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions for library type styling
  defp library_type_icon(:series), do: "hero-tv"
  defp library_type_icon(:movies), do: "hero-film"
  defp library_type_icon(:mixed), do: "hero-square-3-stack-3d"
  defp library_type_icon(:music), do: "hero-musical-note"
  defp library_type_icon(:books), do: "hero-book-open"
  defp library_type_icon(:adult), do: "hero-eye-slash"
  defp library_type_icon(_), do: "hero-folder"

  defp library_type_bg_class(:series), do: "bg-info/10 text-info"
  defp library_type_bg_class(:movies), do: "bg-accent/10 text-accent"
  defp library_type_bg_class(:mixed), do: "bg-secondary/10 text-secondary"
  defp library_type_bg_class(:music), do: "bg-success/10 text-success"
  defp library_type_bg_class(:books), do: "bg-warning/10 text-warning"
  defp library_type_bg_class(:adult), do: "bg-error/10 text-error"
  defp library_type_bg_class(_), do: "bg-base-200 text-base-content/70"

  defp library_type_badge_class(:series), do: "badge-info"
  defp library_type_badge_class(:movies), do: "badge-accent"
  defp library_type_badge_class(:mixed), do: "badge-secondary"
  defp library_type_badge_class(:music), do: "badge-success"
  defp library_type_badge_class(:books), do: "badge-warning"
  defp library_type_badge_class(:adult), do: "badge-error"
  defp library_type_badge_class(_), do: "badge-ghost"

  defp library_type_display(:series), do: "TV Series"
  defp library_type_display(:movies), do: "Movies"
  defp library_type_display(:mixed), do: "Mixed"
  defp library_type_display(:music), do: "Music"
  defp library_type_display(:books), do: "Books"
  defp library_type_display(:adult), do: "Adult"
  defp library_type_display(type), do: to_string(type)

  @doc """
  Renders the scanning/matching progress indicator.

  ## Attributes
    * `:scanning` - Whether currently scanning
    * `:matching` - Whether currently matching files
    * `:scan_stats` - Map with stats (`:total`, `:skipped`)
    * `:scan_progress` - Map with real-time scan progress (`:files_found`)
    * `:match_progress` - Map with real-time match progress (`:matched`, `:total`)
  """
  attr :scanning, :boolean, required: true
  attr :matching, :boolean, required: true
  attr :scan_stats, :map, required: true
  attr :scan_progress, :map, required: true
  attr :match_progress, :map, required: true

  def scanning_progress(assigns) do
    # Calculate match percentage for progress bar
    match_percent =
      if assigns.match_progress.total > 0 do
        round(assigns.match_progress.matched / assigns.match_progress.total * 100)
      else
        0
      end

    assigns = assign(assigns, :match_percent, match_percent)

    ~H"""
    <div class="flex flex-col items-center py-8">
      <%!-- Animated Icon Container --%>
      <div class="relative mb-6">
        <%!-- Pulsing background ring --%>
        <div class={[
          "absolute inset-0 rounded-full animate-ping opacity-20",
          if(@scanning, do: "bg-primary", else: "bg-secondary")
        ]}>
        </div>
        <%!-- Icon container --%>
        <div class={[
          "relative flex items-center justify-center w-20 h-20 rounded-full",
          if(@scanning, do: "bg-primary/10", else: "bg-secondary/10")
        ]}>
          <%= if @scanning do %>
            <.icon name="hero-magnifying-glass" class="w-10 h-10 text-primary animate-pulse" />
          <% else %>
            <.icon name="hero-sparkles" class="w-10 h-10 text-secondary animate-pulse" />
          <% end %>
        </div>
      </div>

      <%!-- Title and description --%>
      <h2 class="text-xl font-bold mb-2">
        {if(@scanning, do: "Scanning Directory", else: "Matching Files")}
      </h2>
      <p class="text-sm text-base-content/60 max-w-md text-center mb-6">
        {if(@scanning,
          do: "Discovering media files in the selected directory...",
          else: "Looking up metadata from TMDB for your media files..."
        )}
      </p>

      <%!-- Progress indicator with file count during scanning --%>
      <%= if @scanning do %>
        <div class="flex items-center gap-2 text-base-content/50 mb-8">
          <span class="loading loading-dots loading-sm"></span>
          <%= if @scan_progress.files_found > 0 do %>
            <span class="text-sm">
              Found <span class="font-bold text-primary">{@scan_progress.files_found}</span> files...
            </span>
          <% else %>
            <span class="text-sm">Scanning in progress</span>
          <% end %>
        </div>
      <% end %>

      <%!-- Progress during matching phase --%>
      <%= if @matching do %>
        <%!-- Progress bar and count --%>
        <div class="w-full max-w-md mb-6">
          <div class="flex justify-between text-sm mb-2">
            <span class="text-base-content/60">
              Matching file {@match_progress.matched} of {@match_progress.total}
            </span>
            <span class="font-bold text-secondary">{@match_percent}%</span>
          </div>
          <progress
            class="progress progress-secondary w-full"
            value={@match_progress.matched}
            max={@match_progress.total}
          >
          </progress>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 w-full max-w-md">
          <%!-- New Files Card --%>
          <div class="card bg-base-100 border border-base-300 shadow-sm">
            <div class="card-body p-4 items-center text-center">
              <div class="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center mb-2">
                <.icon name="hero-document-text" class="w-5 h-5 text-primary" />
              </div>
              <div class="text-3xl font-bold text-primary">{@scan_stats.total}</div>
              <div class="text-xs text-base-content/60">New files to match</div>
            </div>
          </div>

          <%!-- Skipped Files Card --%>
          <%= if @scan_stats.skipped > 0 do %>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4 items-center text-center">
                <div class="w-10 h-10 rounded-full bg-base-200 flex items-center justify-center mb-2">
                  <.icon name="hero-check-circle" class="w-5 h-5 text-base-content/50" />
                </div>
                <div class="text-3xl font-bold text-base-content/50">{@scan_stats.skipped}</div>
                <div class="text-xs text-base-content/60">Already imported</div>
              </div>
            </div>
          <% else %>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body p-4 items-center text-center">
                <div class="w-10 h-10 rounded-full bg-success/10 flex items-center justify-center mb-2">
                  <.icon name="hero-check-circle" class="w-5 h-5 text-success" />
                </div>
                <div class="text-3xl font-bold text-success">0</div>
                <div class="text-xs text-base-content/60">Duplicates found</div>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Subtle hint --%>
        <p class="text-xs text-base-content/40 mt-6 text-center">
          Fetching metadata concurrently to speed up matching
        </p>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the import progress screen.

  ## Attributes
    * `:import_progress` - Map with `:current`, `:total`, and `:current_file`
  """
  attr :import_progress, :map, required: true

  def import_progress_screen(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center">
        <span class="loading loading-spinner loading-lg text-primary"></span>
        <h2 class="card-title mt-4">Importing Files</h2>
        <p class="text-base-content/70">
          Please wait while files are being imported...
        </p>

        <div class="w-full max-w-md mt-6">
          <progress
            class="progress progress-primary w-full"
            value={@import_progress.current}
            max={@import_progress.total}
          >
          </progress>
          <p class="text-sm text-base-content/60 mt-2">
            {@import_progress.current} / {@import_progress.total} files
          </p>
          <%= if @import_progress.current_file do %>
            <p class="text-xs text-base-content/50 mt-1 truncate">
              Current: {@import_progress.current_file}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the stats cards for the review screen.

  ## Attributes
    * `:scan_stats` - Map with `:total`, `:matched`, `:unmatched`, `:skipped`, `:type_filtered`, `:sample_filtered`
  """
  attr :scan_stats, :map, required: true

  def review_stats(assigns) do
    ~H"""
    <div class="stats stats-vertical sm:stats-horizontal shadow-md w-full mb-3 bg-base-100 border border-base-300">
      <div class="stat py-2 px-4">
        <div class="stat-title text-xs">Discovered</div>
        <div class="stat-value text-lg text-primary">{@scan_stats.total}</div>
        <div class="stat-desc text-[10px]">new files</div>
      </div>

      <div class="stat py-2 px-4">
        <div class="stat-title text-xs">Matched</div>
        <div class="stat-value text-lg text-success">{@scan_stats.matched}</div>
        <div class="stat-desc text-[10px]">metadata found</div>
      </div>

      <%= if @scan_stats.unmatched > 0 do %>
        <div class="stat py-2 px-4">
          <div class="stat-title text-xs">Unmatched</div>
          <div class="stat-value text-lg text-warning">{@scan_stats.unmatched}</div>
          <div class="stat-desc text-[10px]">need manual match</div>
        </div>
      <% end %>

      <%= if @scan_stats[:type_filtered] && @scan_stats.type_filtered > 0 do %>
        <div class="stat py-2 px-4">
          <div class="stat-title text-xs">Filtered</div>
          <div class="stat-value text-lg text-info">{@scan_stats.type_filtered}</div>
          <div class="stat-desc text-[10px]">type mismatch</div>
        </div>
      <% end %>

      <%= if @scan_stats[:sample_filtered] && @scan_stats.sample_filtered > 0 do %>
        <div class="stat py-2 px-4">
          <div class="stat-title text-xs">Extras</div>
          <div class="stat-value text-lg text-warning">{@scan_stats.sample_filtered}</div>
          <div class="stat-desc text-[10px]">samples/trailers</div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the selection controls for the review screen.

  ## Attributes
    * `:selected_files` - MapSet of selected file indices
  """
  attr :selected_files, :any, required: true
  attr :batch_selected_count, :integer, default: 0

  def selection_controls(assigns) do
    ~H"""
    <%!-- In-flow toolbar (always visible at normal position) --%>
    <div
      id="selection-toolbar"
      phx-hook="StickyToolbar"
      data-fixed-id="selection-toolbar-fixed"
      class="flex items-center justify-between mb-3"
    >
      <div class="flex items-center gap-4">
        <div class="flex gap-2">
          <button type="button" class="btn btn-sm btn-outline" phx-click="select_all_files">
            Select All
          </button>
          <button type="button" class="btn btn-sm btn-outline" phx-click="deselect_all_files">
            Deselect All
          </button>
        </div>
        <%= if @batch_selected_count > 0 do %>
          <div class="divider divider-horizontal mx-0"></div>
          <div class="flex items-center gap-2">
            <span class="badge badge-info badge-sm gap-1">
              <.icon name="hero-pencil-square" class="w-3 h-3" />
              {@batch_selected_count} selected for editing
            </span>
            <button type="button" class="btn btn-xs btn-ghost" phx-click="batch_deselect_all">
              Clear
            </button>
          </div>
        <% end %>
      </div>
      <div class="flex items-center gap-2">
        <button
          type="button"
          class="btn btn-sm btn-outline btn-info"
          phx-click="batch_select_all"
          title="Select all matched files for batch editing"
        >
          <.icon name="hero-pencil-square" class="w-4 h-4" /> Batch Select
        </button>
        <button
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="start_import"
          disabled={MapSet.size(@selected_files) == 0}
        >
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
          Import ({MapSet.size(@selected_files)})
        </button>
      </div>
    </div>

    <%!-- Fixed toolbar (hidden by default, shown when scrolling past in-flow toolbar) --%>
    <div
      id="selection-toolbar-fixed"
      class="hidden fixed top-14 lg:top-0 left-0 lg:left-64 right-0 z-20 bg-base-100 border-b border-base-300 shadow-sm px-4 py-2"
    >
      <div class="flex items-center justify-between max-w-7xl mx-auto">
        <div class="flex items-center gap-4">
          <div class="flex gap-2">
            <button type="button" class="btn btn-sm btn-outline" phx-click="select_all_files">
              Select All
            </button>
            <button type="button" class="btn btn-sm btn-outline" phx-click="deselect_all_files">
              Deselect All
            </button>
          </div>
          <%= if @batch_selected_count > 0 do %>
            <span class="badge badge-info badge-sm gap-1">
              <.icon name="hero-pencil-square" class="w-3 h-3" />
              {@batch_selected_count} editing
            </span>
          <% end %>
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="start_import"
            disabled={MapSet.size(@selected_files) == 0}
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
            Import ({MapSet.size(@selected_files)})
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders an episode match as a compact list item with inline season/episode editing.

  ## Attributes
    * `:episode` - Episode data with `:index`, `:file`, `:match_result`
    * `:is_selected` - Whether this episode is selected
    * `:is_editing` - Whether the series search is open for this episode
    * `:edit_form` - Edit form data (if editing series)
    * `:search_results` - Search results (if editing series)
  """
  attr :episode, :map, required: true
  attr :is_selected, :boolean, required: true
  attr :is_batch_selected, :boolean, default: false
  attr :is_editing, :boolean, default: false
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def episode_list_item(assigns) do
    ~H"""
    <% match = @episode.match_result %>
    <li class={[
      "flex flex-col gap-1 py-2 px-3 hover:bg-base-200/50 rounded-lg",
      @is_selected && "bg-primary/10",
      @is_batch_selected && "bg-info/5",
      Map.get(match, :match_type) == :partial_match && "bg-warning/5"
    ]}>
      <div class="flex items-center gap-3">
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm"
          checked={@is_selected}
          phx-click="toggle_file_selection"
          phx-value-index={@episode.index}
        />
        <div class="flex-1 min-w-0">
          <%= if Map.get(match, :match_type) == :partial_match do %>
            <p class="font-semibold text-sm truncate text-warning">
              Parsed from: {Path.basename(@episode.file.path)}
            </p>
            <p class="text-xs text-warning">
              Episode not in database - will import with parsed info
            </p>
          <% else %>
            <p class="font-medium text-sm truncate">
              {Path.basename(@episode.file.path)}
            </p>
            <p class="text-xs text-base-content/60">
              {format_file_size(@episode.file.size)}
            </p>
          <% end %>
        </div>
        <%!-- Inline Season Input --%>
        <form
          phx-change="update_episode_inline"
          id={"inline-season-form-#{@episode.index}"}
          phx-debounce="blur"
          class="contents"
        >
          <input type="hidden" name="index" value={@episode.index} />
          <input type="hidden" name="field" value="season" />
          <label class="input input-xs w-16">
            <span class="text-base-content/50 text-xs shrink-0 mr-1">S</span>
            <input
              type="text"
              inputmode="numeric"
              pattern="[0-9]*"
              name="value"
              value={match.parsed_info.season}
              class="grow min-w-0"
            />
          </label>
        </form>
        <%!-- Inline Episode Input --%>
        <form
          phx-change="update_episode_inline"
          id={"inline-episode-form-#{@episode.index}"}
          phx-debounce="blur"
          class="contents"
        >
          <input type="hidden" name="index" value={@episode.index} />
          <input type="hidden" name="field" value="episodes" />
          <label class="input input-xs w-16">
            <span class="text-base-content/50 text-xs shrink-0 mr-1">E</span>
            <input
              type="text"
              name="value"
              value={Enum.join(match.parsed_info.episodes || [], ", ")}
              class="grow"
              placeholder="1, 2"
            />
          </label>
        </form>
        <%!-- Badges --%>
        <div class="flex items-center gap-1.5">
          <%= if Map.get(match, :match_type) == :partial_match do %>
            <div class="badge badge-xs badge-warning gap-1">
              <.icon name="hero-exclamation-circle" class="w-3 h-3" /> Partial
            </div>
          <% end %>
          <%= if Map.get(match, :manually_edited, false) do %>
            <div class="badge badge-xs badge-info gap-1">
              <.icon name="hero-pencil" class="w-3 h-3" /> Edited
            </div>
          <% end %>
          <div class={"badge badge-xs " <> confidence_badge_class(match.match_confidence)}>
            {confidence_label(match.match_confidence)}
          </div>
        </div>
        <%!-- Edit Series Button --%>
        <button
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="edit_file"
          phx-value-index={@episode.index}
          title="Change series match"
        >
          <.icon name="hero-pencil" class="w-3 h-3" />
        </button>
        <%!-- Clear Match Button --%>
        <button
          type="button"
          class="btn btn-xs btn-ghost text-error"
          phx-click="clear_match"
          phx-value-index={@episode.index}
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
        <%!-- Batch Edit Checkbox --%>
        <input
          type="checkbox"
          class="checkbox checkbox-info checkbox-sm"
          checked={@is_batch_selected}
          phx-click="batch_toggle_file"
          phx-value-index={@episode.index}
          data-batch-index={@episode.index}
          title="Select for batch editing"
        />
      </div>
      <%!-- Inline Series Search (shown when editing) --%>
      <%= if @is_editing do %>
        <div class="ml-9 mt-1">
          <.form
            for={%{}}
            phx-submit="save_edit"
            id={"edit-form-#{@episode.index}"}
            class="flex items-center gap-2"
          >
            <div class="relative flex-1">
              <div class="join w-full">
                <span class="join-item flex items-center px-2 bg-base-200 border border-base-300 border-r-0">
                  <.icon name="hero-magnifying-glass" class="w-3.5 h-3.5 text-base-content/50" />
                </span>
                <input
                  type="text"
                  name="edit_form[title]"
                  value={@edit_form["title"]}
                  class="input input-sm join-item flex-1"
                  phx-change="search_series"
                  phx-debounce="300"
                  autocomplete="off"
                  placeholder="Search for series..."
                  autofocus
                />
              </div>
              <%= if @search_results != [] do %>
                <.search_results_dropdown results={@search_results} />
              <% end %>
            </div>
            <input type="hidden" name="edit_form[provider_id]" value={@edit_form["provider_id"]} />
            <input type="hidden" name="edit_form[type]" value={@edit_form["type"]} />
            <input type="hidden" name="edit_form[season]" value={@edit_form["season"]} />
            <input type="hidden" name="edit_form[episodes]" value={@edit_form["episodes"]} />
            <%= if @edit_form["provider_id"] && @edit_form["provider_id"] != "" do %>
              <button type="submit" class="btn btn-primary btn-sm btn-square" title="Apply match">
                <.icon name="hero-check" class="w-4 h-4" />
              </button>
            <% end %>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square"
              phx-click="cancel_edit"
              title="Cancel"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </.form>
        </div>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders a movie match as a compact list item.

  ## Attributes
    * `:movie` - Movie data with `:index`, `:file`, `:match_result`
    * `:is_selected` - Whether this movie is selected
    * `:is_editing` - Whether this movie is being edited
    * `:edit_form` - Edit form data (if editing)
    * `:search_results` - Search results (if editing)
  """
  attr :movie, :map, required: true
  attr :is_selected, :boolean, required: true
  attr :is_batch_selected, :boolean, default: false
  attr :is_editing, :boolean, required: true
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def movie_list_item(assigns) do
    ~H"""
    <% match = @movie.match_result %>
    <li class={[
      "flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg",
      @is_selected && "bg-primary/10",
      @is_batch_selected && "bg-info/5"
    ]}>
      <%= if @is_editing do %>
        <%!-- Edit Form Card --%>
        <div class="card card-compact bg-base-100 border border-primary/30 shadow-lg w-full">
          <div class="card-body gap-4">
            <%!-- Header --%>
            <div class="flex items-start gap-3 pb-2 border-b border-base-300">
              <div class="w-10 h-10 rounded-lg bg-accent/10 flex items-center justify-center shrink-0">
                <.icon name="hero-film" class="w-5 h-5 text-accent" />
              </div>
              <div class="flex-1 min-w-0">
                <h4 class="font-semibold text-sm">Edit Movie Match</h4>
                <p class="text-xs text-base-content/60 truncate">
                  {Path.basename(@movie.file.path)}
                </p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-circle"
                phx-click="cancel_edit"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <.form
              for={%{}}
              phx-submit="save_edit"
              id={"edit-form-#{@movie.index}"}
              class="space-y-4"
            >
              <%!-- Movie Title with Search --%>
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs font-medium">Movie Title</span>
                  <%= if @edit_form["provider_id"] do %>
                    <span class="label-text-alt text-xs text-success">
                      <.icon name="hero-check-circle" class="w-3 h-3 inline" /> Matched
                    </span>
                  <% end %>
                </label>
                <div class="relative">
                  <div class="join w-full">
                    <span class="join-item flex items-center px-3 bg-base-200 border border-base-300 border-r-0">
                      <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/50" />
                    </span>
                    <input
                      type="text"
                      name="edit_form[title]"
                      value={@edit_form["title"]}
                      class="input input-sm join-item flex-1"
                      phx-change="search_series"
                      phx-debounce="300"
                      autocomplete="off"
                      placeholder="Search for movie..."
                    />
                  </div>
                  <%= if @search_results != [] do %>
                    <.search_results_dropdown results={@search_results} />
                  <% end %>
                </div>
              </div>

              <input type="hidden" name="edit_form[provider_id]" value={@edit_form["provider_id"]} />
              <input type="hidden" name="edit_form[type]" value={@edit_form["type"]} />
              <input type="hidden" name="edit_form[season]" value="" />
              <input type="hidden" name="edit_form[episodes]" value="" />

              <%!-- Action Buttons --%>
              <div class="card-actions justify-end pt-2 border-t border-base-300">
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_edit">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm gap-1">
                  <.icon name="hero-check" class="w-4 h-4" /> Save Changes
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% else %>
        <%!-- Normal Display --%>
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm"
          checked={@is_selected}
          phx-click="toggle_file_selection"
          phx-value-index={@movie.index}
        />
        <%!-- Use Map.get for safe access since metadata can be empty (issue #44) --%>
        <%= if poster_path = Map.get(match.metadata || %{}, :poster_path) do %>
          <img
            src={ImageUrl.image_url(poster_path, "w92")}
            alt={match.title}
            class="w-12 h-18 rounded object-cover"
          />
        <% end %>
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-3">
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm truncate">
                {match.title}
                <%= if Map.get(match, :year) do %>
                  ({match.year})
                <% end %>
              </p>
              <p class="text-xs text-base-content/60 truncate">
                {Path.basename(@movie.file.path)}
              </p>
              <p class="text-xs text-base-content/50">
                {format_file_size(@movie.file.size)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <%= if Map.get(match, :manually_edited, false) do %>
                <div class="badge badge-xs badge-info gap-1">
                  <.icon name="hero-pencil" class="w-3 h-3" /> Edited
                </div>
              <% end %>
              <div class={"badge badge-xs " <> confidence_badge_class(match.match_confidence)}>
                {confidence_label(match.match_confidence)}
              </div>
              <div class="badge badge-xs badge-accent">Movie</div>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click="edit_file"
                phx-value-index={@movie.index}
              >
                <.icon name="hero-pencil" class="w-3 h-3" />
              </button>
              <button
                type="button"
                class="btn btn-xs btn-ghost text-error"
                phx-click="clear_match"
                phx-value-index={@movie.index}
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
              <%!-- Batch Edit Checkbox --%>
              <input
                type="checkbox"
                class="checkbox checkbox-info checkbox-sm"
                checked={@is_batch_selected}
                phx-click="batch_toggle_file"
                phx-value-index={@movie.index}
                data-batch-index={@movie.index}
                title="Select for batch editing"
              />
            </div>
          </div>
        </div>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders an unmatched file as a compact list item.

  ## Attributes
    * `:file` - File data with `:index`, `:file`
    * `:is_editing` - Whether this file is being edited
    * `:edit_form` - Edit form data (if editing)
    * `:search_results` - Search results (if editing)
  """
  attr :file, :map, required: true
  attr :is_editing, :boolean, required: true
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def unmatched_file_list_item(assigns) do
    ~H"""
    <li class={"flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg " <> if(!@is_editing, do: "opacity-60", else: "")}>
      <%= if @is_editing do %>
        <%!-- Edit Form Card --%>
        <div class="card card-compact bg-base-100 border border-warning/30 shadow-lg w-full">
          <div class="card-body gap-4">
            <%!-- Header --%>
            <div class="flex items-start gap-3 pb-2 border-b border-base-300">
              <div class="w-10 h-10 rounded-lg bg-warning/10 flex items-center justify-center shrink-0">
                <.icon name="hero-question-mark-circle" class="w-5 h-5 text-warning" />
              </div>
              <div class="flex-1 min-w-0">
                <h4 class="font-semibold text-sm">Find Metadata Match</h4>
                <p class="text-xs text-base-content/60 truncate">
                  {Path.basename(@file.file.path)}
                </p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-circle"
                phx-click="cancel_edit"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <.form
              for={%{}}
              phx-submit="save_edit"
              id={"edit-form-#{@file.index}"}
              class="space-y-4"
            >
              <%!-- Search Field --%>
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-xs font-medium">Search for Title</span>
                  <%= if @edit_form["provider_id"] do %>
                    <span class="label-text-alt text-xs text-success">
                      <.icon name="hero-check-circle" class="w-3 h-3 inline" /> Matched
                    </span>
                  <% end %>
                </label>
                <div class="relative">
                  <div class="join w-full">
                    <span class="join-item flex items-center px-3 bg-base-200 border border-base-300 border-r-0">
                      <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/50" />
                    </span>
                    <input
                      type="text"
                      name="edit_form[title]"
                      value={@edit_form["title"]}
                      class="input input-sm join-item flex-1"
                      phx-change="search_series"
                      phx-debounce="300"
                      autocomplete="off"
                      placeholder="Search by title..."
                    />
                  </div>
                  <%= if @search_results != [] do %>
                    <.search_results_dropdown_with_poster results={@search_results} />
                  <% end %>
                </div>
              </div>

              <input type="hidden" name="edit_form[provider_id]" value={@edit_form["provider_id"]} />
              <input type="hidden" name="edit_form[type]" value={@edit_form["type"]} />

              <%!-- Media Type Indicator --%>
              <%= if @edit_form["provider_id"] do %>
                <div class="flex items-center gap-2 py-2 px-3 bg-base-200/50 rounded-lg">
                  <%= if @edit_form["type"] == "tv_show" do %>
                    <.icon name="hero-tv" class="w-4 h-4 text-info" />
                    <span class="text-xs font-medium">TV Series</span>
                  <% else %>
                    <.icon name="hero-film" class="w-4 h-4 text-accent" />
                    <span class="text-xs font-medium">Movie</span>
                  <% end %>
                </div>
              <% end %>

              <%!-- Conditional Season/Episode Fields --%>
              <%= if @edit_form["type"] == "tv_show" do %>
                <div class="grid grid-cols-2 gap-3">
                  <div class="form-control">
                    <label class="input input-sm">
                      <span class="label">Season</span>
                      <input
                        type="number"
                        name="edit_form[season]"
                        value={@edit_form["season"]}
                        placeholder="1"
                        min="0"
                      />
                    </label>
                  </div>
                  <div class="form-control">
                    <label class="input input-sm">
                      <span class="label">Episode(s)</span>
                      <input
                        type="text"
                        name="edit_form[episodes]"
                        value={@edit_form["episodes"]}
                        placeholder="1, 2"
                      />
                    </label>
                  </div>
                </div>
              <% else %>
                <input type="hidden" name="edit_form[season]" value="" />
                <input type="hidden" name="edit_form[episodes]" value="" />
              <% end %>

              <%!-- Action Buttons --%>
              <div class="card-actions justify-end pt-2 border-t border-base-300">
                <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_edit">
                  Cancel
                </button>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm gap-1"
                  disabled={@edit_form["provider_id"] == nil or @edit_form["provider_id"] == ""}
                >
                  <.icon name="hero-check" class="w-4 h-4" /> Apply Match
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% else %>
        <input type="checkbox" class="checkbox checkbox-primary checkbox-sm" disabled />
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-3">
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm truncate text-error">
                {Path.basename(@file.file.path)}
              </p>
              <%= if parsed_info = Map.get(@file.file, :parsed_info) do %>
                <%= if parsed_info.type == :tv_show && parsed_info.title do %>
                  <p class="text-xs text-base-content/70 mt-1">
                    <span class="font-medium">Parsed as:</span>
                    {parsed_info.title}
                    <%= if parsed_info.season && parsed_info.episodes do %>
                      S{String.pad_leading(to_string(parsed_info.season), 2, "0")}E{String.pad_leading(
                        to_string(hd(parsed_info.episodes)),
                        2,
                        "0"
                      )}
                    <% end %>
                  </p>
                  <p class="text-xs text-warning">
                    Series or episode not found in database
                  </p>
                <% else %>
                  <%= if parsed_info.title do %>
                    <p class="text-xs text-base-content/70 mt-1">
                      <span class="font-medium">Parsed as:</span>
                      {parsed_info.title}
                      <%= if parsed_info.year do %>
                        ({parsed_info.year})
                      <% end %>
                    </p>
                    <p class="text-xs text-warning">Not found in database</p>
                  <% end %>
                <% end %>
              <% else %>
                <p class="text-xs text-base-content/60 truncate">
                  {@file.file.path}
                </p>
              <% end %>
              <p class="text-xs text-base-content/50">
                {format_file_size(@file.file.size)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <div class="badge badge-xs badge-error">No Match</div>
              <button
                type="button"
                class="btn btn-xs btn-primary"
                phx-click="edit_file"
                phx-value-index={@file.index}
              >
                <.icon name="hero-magnifying-glass" class="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </li>
    """
  end

  @doc """
  Renders a type-filtered file as a compact list item.
  These are files that were filtered out due to library type mismatch
  (e.g., movies in a TV-only library).

  ## Attributes
    * `:file` - File data with `:file`, `:match_result`
    * `:library_type` - The type of the library being scanned (:series, :movies, :mixed)
  """
  attr :file, :map, required: true
  attr :library_type, :atom, default: nil

  def type_filtered_list_item(assigns) do
    ~H"""
    <li class="flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg opacity-60">
      <div class="text-info mt-1">
        <.icon name="hero-funnel" class="w-4 h-4" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <p class="font-medium text-sm truncate">
              {Path.basename(@file.file.path)}
            </p>
            <%= if @file.match_result do %>
              <p class="text-xs text-base-content/60 truncate">
                {type_mismatch_reason(@file.match_result, @library_type)}
              </p>
            <% end %>
            <p class="text-xs text-base-content/50">
              {format_file_size(@file.file.size)}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <%= if @file.match_result do %>
              <div class={"badge badge-xs " <> media_type_badge_class(@file.match_result.parsed_info.type)}>
                {media_type_label(@file.match_result.parsed_info.type)}
              </div>
            <% end %>
            <div class="badge badge-xs badge-info">Filtered</div>
          </div>
        </div>
      </div>
    </li>
    """
  end

  @doc """
  Renders a list item for sample/trailer/extra filtered files.
  Displays why the file was filtered with detection reason.

  ## Attributes
    * `:file` - File data with match_result containing parsed_info with detection info
  """
  attr :file, :map, required: true

  def sample_filtered_list_item(assigns) do
    ~H"""
    <li class="flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg opacity-60">
      <div class="text-warning mt-1">
        <.icon name="hero-film" class="w-4 h-4" />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <p class="font-medium text-sm truncate">
              {Path.basename(@file.file.path)}
            </p>
            <p class="text-xs text-base-content/60 truncate">
              {sample_detection_reason(@file)}
            </p>
            <p class="text-xs text-base-content/50">
              {format_file_size(@file.file.size)}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <div class={sample_type_badge_class(@file)}>
              {sample_type_label(@file)}
            </div>
            <div class="badge badge-xs badge-warning">Filtered</div>
          </div>
        </div>
      </div>
    </li>
    """
  end

  defp sample_detection_reason(%{match_result: nil} = file) do
    "Unknown (no match result): #{file.file.path}"
  end

  defp sample_detection_reason(%{match_result: match}) do
    parsed_info = match.parsed_info

    cond do
      parsed_info.is_sample ->
        case parsed_info.detection_method do
          :folder -> "Sample file detected in #{parsed_info.detected_folder} folder"
          :filename -> "Sample file detected from filename pattern"
          _ -> "Sample file"
        end

      parsed_info.is_trailer ->
        case parsed_info.detection_method do
          :folder -> "Trailer detected in #{parsed_info.detected_folder} folder"
          :filename -> "Trailer detected from filename pattern"
          _ -> "Trailer"
        end

      parsed_info.is_extra ->
        case parsed_info.detection_method do
          :folder -> "Extra content in #{parsed_info.detected_folder} folder"
          :filename -> "Extra content detected from filename pattern"
          _ -> "Extra content"
        end

      true ->
        "Unknown filter reason"
    end
  end

  defp sample_type_badge_class(%{match_result: nil}), do: "badge badge-xs badge-ghost"

  defp sample_type_badge_class(%{match_result: match}) do
    parsed_info = match.parsed_info

    cond do
      parsed_info.is_sample -> "badge badge-xs badge-warning"
      parsed_info.is_trailer -> "badge badge-xs badge-info"
      parsed_info.is_extra -> "badge badge-xs badge-secondary"
      true -> "badge badge-xs badge-ghost"
    end
  end

  defp sample_type_label(%{match_result: nil}), do: "Unknown"

  defp sample_type_label(%{match_result: match}) do
    parsed_info = match.parsed_info

    cond do
      parsed_info.is_sample -> "Sample"
      parsed_info.is_trailer -> "Trailer"
      parsed_info.is_extra -> "Extra"
      true -> "Unknown"
    end
  end

  @doc """
  Renders a simple file list item for specialized libraries (music, books, adult).
  These files don't need metadata matching - just display basic file info.

  ## Attributes
    * `:file` - File data with `:file` map containing path, size, etc.
    * `:index` - The index of this file in the matched_files list
    * `:is_selected` - Whether this file is selected for import
  """
  attr :file, :map, required: true
  attr :index, :integer, required: true
  attr :is_selected, :boolean, required: true

  def simple_file_list_item(assigns) do
    ~H"""
    <li class="flex items-center gap-3 py-2 px-3 hover:bg-base-200/50 rounded-lg">
      <input
        type="checkbox"
        class="checkbox checkbox-primary checkbox-sm"
        checked={@is_selected}
        phx-click="toggle_file_selection"
        phx-value-index={@index}
      />
      <div class="flex-1 min-w-0">
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <p class="font-medium text-sm truncate">
              {Path.basename(@file.file.path)}
            </p>
            <p class="text-xs text-base-content/60 truncate">
              {@file.file.path}
            </p>
            <p class="text-xs text-base-content/50">
              {format_file_size(@file.file.size)}
              <%= if @file.file[:modified_at] do %>
                • {format_date(@file.file.modified_at)}
              <% end %>
            </p>
          </div>
          <div class="flex items-center gap-2">
            <div class="badge badge-xs badge-ghost">
              {file_extension(@file.file.path)}
            </div>
          </div>
        </div>
      </div>
    </li>
    """
  end

  defp file_extension(path) do
    case Path.extname(path) do
      "" -> "file"
      ext -> String.upcase(String.trim_leading(ext, "."))
    end
  end

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_date(_), do: nil

  @doc """
  Renders a search results dropdown (compact version).

  ## Attributes
    * `:results` - List of search result maps
  """
  attr :results, :list, required: true

  def search_results_dropdown(assigns) do
    ~H"""
    <div class="absolute z-20 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-56 overflow-y-auto">
      <div class="py-1">
        <%= for result <- @results do %>
          <button
            type="button"
            class="w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors flex items-center gap-3"
            phx-click="select_search_result"
            phx-value-provider_id={result.provider_id}
            phx-value-title={result.title}
            phx-value-year={result.year || ""}
            phx-value-type={result.media_type}
          >
            <div class={"w-8 h-8 rounded flex items-center justify-center shrink-0 " <>
              if(result.media_type == :tv_show or result.media_type == "tv_show", do: "bg-info/10 text-info", else: "bg-accent/10 text-accent")
            }>
              <%= if result.media_type == :tv_show or result.media_type == "tv_show" do %>
                <.icon name="hero-tv" class="w-4 h-4" />
              <% else %>
                <.icon name="hero-film" class="w-4 h-4" />
              <% end %>
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{result.title}</div>
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <%= if result.year do %>
                  <span>{result.year}</span>
                  <span>•</span>
                <% end %>
                <span class={
                  if(result.media_type == :tv_show or result.media_type == "tv_show",
                    do: "text-info",
                    else: "text-accent"
                  )
                }>
                  {if(result.media_type == :tv_show or result.media_type == "tv_show",
                    do: "TV Series",
                    else: "Movie"
                  )}
                </span>
              </div>
            </div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a search results dropdown with poster images.

  ## Attributes
    * `:results` - List of search result maps
  """
  attr :results, :list, required: true

  def search_results_dropdown_with_poster(assigns) do
    ~H"""
    <div class="absolute z-20 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-72 overflow-y-auto">
      <div class="py-1">
        <%= for result <- @results do %>
          <button
            type="button"
            class="w-full text-left px-3 py-2.5 hover:bg-primary/10 transition-colors flex items-center gap-3"
            phx-click="select_search_result"
            phx-value-provider_id={result.provider_id}
            phx-value-title={result.title}
            phx-value-year={result.year || ""}
            phx-value-type={result.media_type}
          >
            <%= if result.poster_path do %>
              <img
                src={ImageUrl.image_url(result.poster_path, "w92")}
                alt={result.title}
                class="w-10 h-14 rounded object-cover shadow-sm"
              />
            <% else %>
              <div class={"w-10 h-14 rounded flex items-center justify-center shrink-0 " <>
                if(result.media_type == :tv_show or result.media_type == "tv_show", do: "bg-info/10 text-info", else: "bg-accent/10 text-accent")
              }>
                <%= if result.media_type == :tv_show or result.media_type == "tv_show" do %>
                  <.icon name="hero-tv" class="w-5 h-5" />
                <% else %>
                  <.icon name="hero-film" class="w-5 h-5" />
                <% end %>
              </div>
            <% end %>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{result.title}</div>
              <div class="flex items-center gap-2 text-xs text-base-content/60 mt-0.5">
                <%= if result.year do %>
                  <span>{result.year}</span>
                  <span>•</span>
                <% end %>
                <span class={[
                  "badge badge-xs",
                  if(result.media_type == :tv_show or result.media_type == "tv_show",
                    do: "badge-info",
                    else: "badge-accent"
                  )
                ]}>
                  {if(result.media_type == :tv_show or result.media_type == "tv_show",
                    do: "TV Series",
                    else: "Movie"
                  )}
                </span>
              </div>
            </div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a search results dropdown for series re-matching.
  Only shows TV series results and fires the `select_series_rematch` event.

  ## Attributes
    * `:results` - List of search result maps
  """
  attr :results, :list, required: true

  def series_search_results_dropdown(assigns) do
    ~H"""
    <div class="absolute z-20 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-56 overflow-y-auto">
      <div class="py-1">
        <%= for result <- @results do %>
          <button
            type="button"
            class="w-full text-left px-3 py-2 hover:bg-primary/10 transition-colors flex items-center gap-3"
            phx-click="select_series_rematch"
            phx-value-provider_id={result.provider_id}
            phx-value-title={result.title}
            phx-value-year={result.year || ""}
            phx-value-type={result.media_type}
          >
            <%= if result.poster_path do %>
              <img
                src={ImageUrl.image_url(result.poster_path, "w92")}
                alt={result.title}
                class="w-8 h-12 rounded object-cover shadow-sm"
              />
            <% else %>
              <div class="w-8 h-8 rounded flex items-center justify-center shrink-0 bg-info/10 text-info">
                <.icon name="hero-tv" class="w-4 h-4" />
              </div>
            <% end %>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{result.title}</div>
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <%= if result.year do %>
                  <span>{result.year}</span>
                  <span>•</span>
                <% end %>
                <span class="text-info">TV Series</span>
              </div>
            </div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the batch edit toolbar that appears at the bottom of the screen.

  Shows when at least one file is selected for batch editing, providing
  a search input for series/movie, season number input, and apply button.

  ## Attributes
    * `:batch_selected_count` - Number of files selected for batch editing
    * `:batch_search_query` - Current search text in toolbar
    * `:batch_search_results` - Search results dropdown items
    * `:batch_selected_match` - The chosen match (map with title, provider_id, year, type) or nil
    * `:batch_season_value` - Current season input value
    * `:library_type` - Library type atom (:series, :movies, :mixed, etc.)
  """
  attr :batch_selected_count, :integer, required: true
  attr :batch_search_query, :string, default: ""
  attr :batch_search_results, :list, default: []
  attr :batch_selected_match, :map, default: nil
  attr :batch_season_value, :string, default: ""
  attr :library_type, :atom, default: nil

  def batch_edit_toolbar(assigns) do
    ~H"""
    <div
      id="batch-edit-toolbar"
      class={[
        "fixed bottom-0 left-0 lg:left-64 right-0 z-30 bg-base-100 border-t border-base-300 shadow-[0_-4px_12px_rgba(0,0,0,0.15)] transition-transform duration-300",
        if(@batch_selected_count > 0, do: "translate-y-0", else: "translate-y-full")
      ]}
    >
      <div class="max-w-7xl mx-auto px-4 py-3">
        <div class="flex items-center gap-3 flex-wrap">
          <%!-- Selected count --%>
          <div class="flex items-center gap-2 shrink-0">
            <span class="badge badge-info gap-1">
              <.icon name="hero-pencil-square" class="w-3.5 h-3.5" />
              {@batch_selected_count} selected
            </span>
            <button type="button" class="btn btn-xs btn-ghost" phx-click="batch_deselect_all">
              Clear
            </button>
          </div>

          <div class="divider divider-horizontal mx-0"></div>

          <%!-- Series/Movie Search --%>
          <div class="flex-1 min-w-48 max-w-sm relative">
            <%= if @batch_selected_match do %>
              <%!-- Show selected match as badge --%>
              <div class="flex items-center gap-2">
                <div class="badge badge-success gap-1">
                  <.icon name="hero-check-circle" class="w-3.5 h-3.5" />
                  {@batch_selected_match.title}
                  <%= if @batch_selected_match.year do %>
                    ({@batch_selected_match.year})
                  <% end %>
                </div>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost btn-circle"
                  phx-click="batch_clear_match"
                  title="Clear match"
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
              </div>
            <% else %>
              <%!-- Search input --%>
              <div class="join w-full">
                <span class="join-item flex items-center px-2 bg-base-200 border border-base-300 border-r-0">
                  <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/50" />
                </span>
                <input
                  type="text"
                  name="query"
                  value={@batch_search_query}
                  placeholder="Search series or movie..."
                  class="input input-sm join-item flex-1"
                  phx-keyup="batch_search"
                  phx-debounce="300"
                  autocomplete="off"
                />
              </div>
              <%!-- Upward-opening dropdown --%>
              <%= if @batch_search_results != [] do %>
                <.batch_search_results_dropdown results={@batch_search_results} />
              <% end %>
            <% end %>
          </div>

          <%!-- Season Input (only for non-movie libraries) --%>
          <%= if @library_type not in [:movies] do %>
            <label class="input input-sm w-20">
              <span class="text-base-content/50 text-xs shrink-0 mr-1">S</span>
              <input
                type="text"
                inputmode="numeric"
                pattern="[0-9]*"
                name="value"
                value={@batch_season_value}
                placeholder="#"
                phx-keyup="batch_update_season"
                phx-debounce="300"
                class="grow min-w-0"
              />
            </label>
          <% end %>

          <%!-- Apply Button --%>
          <button
            type="button"
            class="btn btn-sm btn-info shrink-0"
            phx-click="batch_apply"
            disabled={@batch_selected_match == nil and String.trim(@batch_season_value) == ""}
          >
            <.icon name="hero-check" class="w-4 h-4" /> Apply to {@batch_selected_count}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :results, :list, required: true

  defp batch_search_results_dropdown(assigns) do
    ~H"""
    <div class="absolute z-30 w-full bottom-full mb-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-56 overflow-y-auto">
      <div class="py-1">
        <%= for result <- @results do %>
          <button
            type="button"
            class="w-full text-left px-3 py-2 hover:bg-info/10 transition-colors flex items-center gap-3"
            phx-click="batch_select_search_result"
            phx-value-provider_id={result.provider_id}
            phx-value-title={result.title}
            phx-value-year={result.year || ""}
            phx-value-type={result.media_type}
          >
            <div class={[
              "w-8 h-8 rounded flex items-center justify-center shrink-0",
              if(result.media_type == :tv_show or result.media_type == "tv_show",
                do: "bg-info/10 text-info",
                else: "bg-accent/10 text-accent"
              )
            ]}>
              <%= if result.media_type == :tv_show or result.media_type == "tv_show" do %>
                <.icon name="hero-tv" class="w-4 h-4" />
              <% else %>
                <.icon name="hero-film" class="w-4 h-4" />
              <% end %>
            </div>
            <div class="flex-1 min-w-0">
              <div class="font-medium text-sm truncate">{result.title}</div>
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <%= if result.year do %>
                  <span>{result.year}</span>
                  <span>•</span>
                <% end %>
                <span class={
                  if(result.media_type == :tv_show or result.media_type == "tv_show",
                    do: "text-info",
                    else: "text-accent"
                  )
                }>
                  {if(result.media_type == :tv_show or result.media_type == "tv_show",
                    do: "TV Series",
                    else: "Movie"
                  )}
                </span>
              </div>
            </div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders the import completion screen with results.

  ## Attributes
    * `:import_results` - Map with `:success`, `:failed`, `:skipped` counts
    * `:detailed_results` - List of detailed result maps
  """
  attr :import_results, :map, required: true
  attr :detailed_results, :list, required: true

  def import_complete_screen(assigns) do
    ~H"""
    <div class="mb-6">
      <%!-- Summary Stats with Header --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 sm:gap-3 mb-4">
        <%!-- Total Processed --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-3 sm:p-4 text-center">
            <div class={[
              "mx-auto w-8 h-8 sm:w-10 sm:h-10 rounded-full flex items-center justify-center mb-1 sm:mb-2",
              if(@import_results.failed == 0, do: "bg-success/10", else: "bg-warning/10")
            ]}>
              <.icon
                name={
                  if(@import_results.failed == 0,
                    do: "hero-check-circle",
                    else: "hero-exclamation-triangle"
                  )
                }
                class={
                  "w-4 h-4 sm:w-5 sm:h-5 " <>
                    if(@import_results.failed == 0, do: "text-success", else: "text-warning")
                }
              />
            </div>
            <div class="text-xl sm:text-2xl font-bold">
              {@import_results.success + @import_results.failed + @import_results.skipped}
            </div>
            <div class="text-[10px] sm:text-xs text-base-content/60">Total Processed</div>
          </div>
        </div>

        <%!-- Imported --%>
        <div class="card bg-base-100 border border-success/30 shadow-sm">
          <div class="card-body p-3 sm:p-4 text-center">
            <div class="mx-auto w-8 h-8 sm:w-10 sm:h-10 rounded-full bg-success/10 flex items-center justify-center mb-1 sm:mb-2">
              <.icon name="hero-check-circle" class="w-4 h-4 sm:w-5 sm:h-5 text-success" />
            </div>
            <div class="text-xl sm:text-2xl font-bold text-success">{@import_results.success}</div>
            <div class="text-[10px] sm:text-xs text-base-content/60">Imported</div>
          </div>
        </div>

        <%!-- Failed --%>
        <div class={[
          "card bg-base-100 shadow-sm",
          if(@import_results.failed > 0, do: "border border-error/30", else: "border border-base-300")
        ]}>
          <div class="card-body p-3 sm:p-4 text-center">
            <div class={[
              "mx-auto w-8 h-8 sm:w-10 sm:h-10 rounded-full flex items-center justify-center mb-1 sm:mb-2",
              if(@import_results.failed > 0, do: "bg-error/10", else: "bg-base-200")
            ]}>
              <.icon
                name="hero-x-circle"
                class={
                  "w-4 h-4 sm:w-5 sm:h-5 " <>
                    if(@import_results.failed > 0, do: "text-error", else: "text-base-content/30")
                }
              />
            </div>
            <div class={[
              "text-xl sm:text-2xl font-bold",
              if(@import_results.failed > 0, do: "text-error", else: "text-base-content/30")
            ]}>
              {@import_results.failed}
            </div>
            <div class="text-[10px] sm:text-xs text-base-content/60">Failed</div>
          </div>
        </div>

        <%!-- Skipped --%>
        <div class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-3 sm:p-4 text-center">
            <div class="mx-auto w-8 h-8 sm:w-10 sm:h-10 rounded-full bg-base-200 flex items-center justify-center mb-1 sm:mb-2">
              <.icon name="hero-minus-circle" class="w-4 h-4 sm:w-5 sm:h-5 text-base-content/50" />
            </div>
            <div class="text-xl sm:text-2xl font-bold text-base-content/50">
              {@import_results.skipped}
            </div>
            <div class="text-[10px] sm:text-xs text-base-content/60">Skipped</div>
          </div>
        </div>
      </div>

      <%!-- Action Buttons - Stack on mobile --%>
      <div class="flex flex-col sm:flex-row sm:items-center gap-2 sm:justify-between mb-4">
        <div class="flex flex-wrap gap-2">
          <%= if @import_results.failed > 0 do %>
            <button
              type="button"
              class="btn btn-warning btn-sm flex-1 sm:flex-none"
              phx-click="retry_all_failed"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" />
              <span class="hidden xs:inline">Retry All Failed</span>
              <span class="xs:hidden">Retry</span>
            </button>
          <% end %>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="export_results">
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
            <span class="hidden sm:inline">Export Details</span>
            <span class="sm:hidden">Export</span>
          </button>
        </div>
        <div class="flex gap-2">
          <button
            type="button"
            class="btn btn-outline btn-sm flex-1 sm:flex-none"
            phx-click="start_over"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" />
            <span class="hidden sm:inline">Import More</span>
            <span class="sm:hidden">More</span>
          </button>
          <button type="button" class="btn btn-primary btn-sm flex-1 sm:flex-none" phx-click="cancel">
            <.icon name="hero-check" class="w-4 h-4" /> Done
          </button>
        </div>
      </div>

      <%!-- Detailed Results --%>
      <%= if @import_results.success > 0 do %>
        <div class="mb-4 sm:mb-6">
          <h3 class="text-base sm:text-lg font-semibold mb-2 sm:mb-3 flex items-center gap-2">
            <.icon name="hero-check-circle" class="w-5 h-5 sm:w-6 sm:h-6 text-success" />
            Successfully Imported ({@import_results.success})
          </h3>
          <div class="space-y-1.5 sm:space-y-2">
            <%= for {result, _idx} <- Enum.with_index(@detailed_results) do %>
              <%= if result.status == :success do %>
                <div class="card bg-base-100 shadow-sm border border-success/20">
                  <div class="card-body p-2.5 sm:p-4">
                    <div class="flex items-start gap-2 sm:gap-3">
                      <div class="text-success mt-0.5 sm:mt-1 shrink-0">
                        <.icon name="hero-check-circle" class="w-4 h-4 sm:w-5 sm:h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class="font-semibold text-xs sm:text-sm truncate">{result.file_name}</p>
                        <p class="text-[10px] sm:text-xs text-base-content/60 truncate hidden sm:block">
                          {result.file_path}
                        </p>
                        <%= if result.action_taken do %>
                          <p class="text-[10px] sm:text-xs text-success mt-0.5 sm:mt-1 line-clamp-1">
                            {result.action_taken}
                          </p>
                        <% end %>
                      </div>
                      <div class="badge badge-success badge-xs sm:badge-sm shrink-0">Success</div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @import_results.failed > 0 do %>
        <div class="mb-4 sm:mb-6">
          <h3 class="text-base sm:text-lg font-semibold mb-2 sm:mb-3 flex items-center gap-2">
            <.icon name="hero-x-circle" class="w-5 h-5 sm:w-6 sm:h-6 text-error" />
            Failed ({@import_results.failed})
          </h3>
          <div class="space-y-1.5 sm:space-y-2">
            <%= for {result, idx} <- Enum.with_index(@detailed_results) do %>
              <%= if result.status == :failed do %>
                <div class="card bg-base-100 shadow-sm border border-error/20">
                  <div class="card-body p-2.5 sm:p-4">
                    <div class="flex items-start gap-2 sm:gap-3">
                      <div class="text-error mt-0.5 sm:mt-1 shrink-0">
                        <.icon name="hero-x-circle" class="w-4 h-4 sm:w-5 sm:h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-start justify-between gap-2">
                          <p class="font-semibold text-xs sm:text-sm truncate flex-1">
                            {result.file_name}
                          </p>
                          <div class="flex items-center gap-1.5 sm:gap-2 shrink-0">
                            <div class="badge badge-error badge-xs sm:badge-sm">Failed</div>
                            <button
                              type="button"
                              class="btn btn-xs btn-warning"
                              phx-click="retry_failed_item"
                              phx-value-index={idx}
                            >
                              <.icon name="hero-arrow-path" class="w-3 h-3" />
                              <span class="hidden sm:inline">Retry</span>
                            </button>
                          </div>
                        </div>
                        <p class="text-[10px] sm:text-xs text-base-content/60 truncate hidden sm:block">
                          {result.file_path}
                        </p>
                        <%= if result.error_message do %>
                          <div class="alert alert-error mt-1.5 sm:mt-2 py-1.5 sm:py-2 px-2 sm:px-3">
                            <.icon
                              name="hero-exclamation-triangle"
                              class="w-3 h-3 sm:w-4 sm:h-4 shrink-0"
                            />
                            <span class="text-[10px] sm:text-xs line-clamp-2">
                              {result.error_message}
                            </span>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @import_results.skipped > 0 do %>
        <div class="mb-4 sm:mb-6">
          <h3 class="text-base sm:text-lg font-semibold mb-2 sm:mb-3 flex items-center gap-2">
            <.icon name="hero-minus-circle" class="w-5 h-5 sm:w-6 sm:h-6 text-base-content/50" />
            Skipped ({@import_results.skipped})
          </h3>
          <div class="space-y-1.5 sm:space-y-2">
            <%= for {result, _idx} <- Enum.with_index(@detailed_results) do %>
              <%= if result.status == :skipped do %>
                <div class="card bg-base-100 shadow-sm border border-base-content/10">
                  <div class="card-body p-2.5 sm:p-4">
                    <div class="flex items-start gap-2 sm:gap-3">
                      <div class="text-base-content/50 mt-0.5 sm:mt-1 shrink-0">
                        <.icon name="hero-minus-circle" class="w-4 h-4 sm:w-5 sm:h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class="font-semibold text-xs sm:text-sm truncate">{result.file_name}</p>
                        <p class="text-[10px] sm:text-xs text-base-content/60 truncate hidden sm:block">
                          {result.file_path}
                        </p>
                        <%= if result.error_message do %>
                          <p class="text-[10px] sm:text-xs text-base-content/50 mt-0.5 sm:mt-1 line-clamp-1">
                            {result.error_message}
                          </p>
                        <% end %>
                      </div>
                      <div class="badge badge-ghost badge-xs sm:badge-sm shrink-0">Skipped</div>
                    </div>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a prompt to resume an existing import session or start fresh.

  ## Attributes
    * `:pending_session` - The active import session that can be resumed
  """
  attr :pending_session, :any, required: true

  def resume_session_prompt(assigns) do
    # Calculate how long ago the session was active
    time_ago = format_time_ago(assigns.pending_session.updated_at)

    # Get step label for display
    step_label =
      case assigns.pending_session.step do
        :select_path -> "Path Selection"
        :review -> "Review Matches"
        :importing -> "Import in Progress"
        :complete -> "Completed"
        step -> to_string(step)
      end

    assigns =
      assigns
      |> assign(:time_ago, time_ago)
      |> assign(:step_label, step_label)

    ~H"""
    <div class="flex flex-col items-center py-12">
      <%!-- Icon --%>
      <div class="relative mb-6">
        <div class="flex items-center justify-center w-20 h-20 rounded-full bg-info/10">
          <.icon name="hero-arrow-path" class="w-10 h-10 text-info" />
        </div>
      </div>

      <%!-- Title --%>
      <h2 class="text-xl font-bold mb-2">Resume Previous Import?</h2>
      <p class="text-sm text-base-content/60 max-w-md text-center mb-6">
        You have an active import session that was last updated {@time_ago}.
      </p>

      <%!-- Session Details Card --%>
      <div class="card bg-base-200 border border-base-300 w-full max-w-md mb-6">
        <div class="card-body py-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-info/20">
                <.icon name="hero-folder-open" class="w-5 h-5 text-info" />
              </div>
              <div>
                <p class="font-semibold text-sm">Import Session</p>
                <p class="text-xs text-base-content/60">
                  Step: {@step_label}
                </p>
              </div>
            </div>
            <div class="badge badge-info badge-sm">Active</div>
          </div>

          <%= if @pending_session.scan_path do %>
            <div class="divider my-2"></div>
            <div class="flex items-center gap-2">
              <.icon name="hero-folder" class="w-4 h-4 text-base-content/50" />
              <p class="text-xs font-mono text-base-content/70 truncate">
                {@pending_session.scan_path}
              </p>
            </div>
          <% end %>

          <%= if @pending_session.scan_stats && @pending_session.scan_stats["total"] do %>
            <div class="flex gap-4 mt-2">
              <div class="text-xs">
                <span class="text-base-content/60">Files:</span>
                <span class="font-semibold">{@pending_session.scan_stats["total"]}</span>
              </div>
              <%= if @pending_session.scan_stats["matched"] do %>
                <div class="text-xs">
                  <span class="text-base-content/60">Matched:</span>
                  <span class="font-semibold text-success">
                    {@pending_session.scan_stats["matched"]}
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Action Buttons --%>
      <div class="flex gap-3">
        <button type="button" phx-click="start_fresh" class="btn btn-ghost">
          <.icon name="hero-plus" class="w-4 h-4" /> Start Fresh
        </button>
        <button type="button" phx-click="resume_session" class="btn btn-primary">
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Resume Session
        </button>
      </div>
    </div>
    """
  end

  # Formats a DateTime as a human-readable relative time string
  defp format_time_ago(nil), do: "some time ago"

  defp format_time_ago(datetime) do
    now = DateTime.utc_now()

    # Handle both DateTime and NaiveDateTime
    datetime_utc =
      case datetime do
        %DateTime{} -> datetime
        %NaiveDateTime{} -> DateTime.from_naive!(datetime, "Etc/UTC")
        _ -> now
      end

    diff_seconds = DateTime.diff(now, datetime_utc, :second)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)} hours ago"
      diff_seconds < 604_800 -> "#{div(diff_seconds, 86400)} days ago"
      true -> "over a week ago"
    end
  end

  ## Helper Functions

  defp format_file_size(size) when size < 1024, do: "#{size} B"
  defp format_file_size(size) when size < 1_048_576, do: "#{Float.round(size / 1024, 1)} KB"

  defp format_file_size(size) when size < 1_073_741_824,
    do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_file_size(size), do: "#{Float.round(size / 1_073_741_824, 1)} GB"

  defp confidence_badge_class(confidence) when confidence >= 0.8, do: "badge-success"
  defp confidence_badge_class(confidence) when confidence >= 0.5, do: "badge-warning"
  defp confidence_badge_class(_), do: "badge-error"

  defp confidence_label(confidence) when confidence >= 0.8, do: "High"
  defp confidence_label(confidence) when confidence >= 0.5, do: "Medium"
  defp confidence_label(_), do: "Low"

  defp media_type_badge_class(:movie), do: "badge-accent"
  defp media_type_badge_class(:tv_show), do: "badge-info"
  defp media_type_badge_class(_), do: "badge-ghost"

  defp media_type_label(:movie), do: "Movie"
  defp media_type_label(:tv_show), do: "TV Show"
  defp media_type_label(_), do: "Unknown"

  defp type_mismatch_reason(match_result, :series) when match_result.parsed_info.type == :movie do
    "Movie detected in TV series library: \"#{match_result.title}\""
  end

  defp type_mismatch_reason(match_result, :movies)
       when match_result.parsed_info.type == :tv_show do
    "TV show detected in movies library: \"#{match_result.title}\""
  end

  defp type_mismatch_reason(match_result, _library_type) do
    "Type mismatch: \"#{match_result.title}\" (#{media_type_label(match_result.parsed_info.type)})"
  end
end
