defmodule MydiaWeb.ImportMediaLive.Components do
  @moduledoc """
  Reusable UI components for the grouped import review table.

  Each component renders from an `Mydia.Library.ImportGroup` row (or a page of
  them), never from a loaded collection of files: that is what keeps the page
  independent of how many files a group actually has.
  """

  use Phoenix.Component
  import MydiaWeb.CoreComponents

  alias Mydia.Metadata.ImageUrl

  @doc """
  A row of buttons for switching which library the review section shows.

  Only meaningful with more than one importable library path -- the caller
  is expected to gate rendering on that, same as the `filter` this row of
  buttons resembles. `counts` maps `library_path_id` to its pending group
  total (`ImportGroups.band_counts/1`'s `:total`, one call per path), so a
  user picking between two libraries can see where the work actually is
  before switching to it.
  """
  attr :library_paths, :list, required: true
  attr :selected_id, :string, required: true
  attr :counts, :map, required: true

  def library_picker(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 flex-wrap bg-base-200/50 p-1 rounded-xl border border-base-200">
      <button
        :for={path <- @library_paths}
        type="button"
        id={"library-picker-#{path.id}"}
        class={[
          "btn btn-sm transition-all",
          if(path.id == @selected_id,
            do: "btn-primary shadow-sm",
            else: "btn-ghost text-base-content/70 hover:text-base-content"
          )
        ]}
        phx-click="select_library"
        phx-value-library_path_id={path.id}
      >
        <.icon
          name={if(path.type == :movies, do: "hero-film", else: "hero-tv")}
          class="w-4 h-4 mr-1 opacity-70"
        />
        {path.path}
        <span class={[
          "badge badge-sm ml-1",
          if(path.id == @selected_id,
            do: "badge-primary-content text-primary font-bold",
            else: "badge-ghost"
          )
        ]}>
          {Map.get(@counts, path.id, 0)}
        </span>
      </button>
    </div>
    """
  end

  @doc """
  The band filter chips plus the folder search box.

  `counts` is `ImportGroups.band_counts/1`'s return shape: `:ready`,
  `:needs_attention`, `:no_match` and `:total`. `:all` has no key of its own
  in that map, so `count_for/2` reads `:total` for it instead.

  Each chip is a `<label>` wrapping a checkbox rather than a bare
  `<input class="btn">`: daisyUI's own `.filter` CSS supports both (it targets
  `input` by descendant selector, not only direct children), and a bare input
  can only carry a count via its `aria-label`, which is invisible to anything
  that reads the rendered markup rather than paints it -- including this
  page's own tests.
  """
  attr :band, :atom, required: true
  attr :counts, :map, required: true
  attr :search, :string, default: ""

  def band_filter(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 flex-wrap">
      <div class="filter flex items-center gap-1.5 flex-wrap">
        <label
          :for={
            {band, id, label} <- [
              {:all, "band-all", "All"},
              {:ready, "band-ready", "Ready"},
              {:needs_attention, "band-needs-attention", "Needs attention"},
              {:no_match, "band-no-match", "No match"},
              {:ignored, "band-ignored", "Ignored"}
            ]
          }
          id={id}
          class={[
            "btn btn-sm gap-1.5 rounded-lg border cursor-pointer",
            if(@band == band,
              do: "btn-active btn-primary border-primary",
              else: "btn-ghost border-base-200 bg-base-100 hover:bg-base-200"
            )
          ]}
          phx-click="select_band"
          phx-value-band={band}
        >
          <input type="checkbox" class="sr-only" checked={@band == band} tabindex="-1" />
          {label}
          <span class={[
            "badge badge-sm font-semibold",
            if(@band == band, do: "badge-primary-content text-primary", else: "badge-ghost")
          ]}>
            {count_for(@counts, band)}
          </span>
        </label>
      </div>

      <form phx-change="search" id="import-search-form" class="ml-auto w-full sm:w-auto">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 opacity-50"
          />
          <input
            type="text"
            name="q"
            value={@search}
            placeholder="Search folder…"
            phx-debounce="300"
            class="input input-sm input-bordered pl-9 w-full sm:w-64"
          />
        </div>
      </form>
    </div>
    """
  end

  defp count_for(counts, :all), do: counts.total
  defp count_for(counts, band), do: Map.get(counts, band, 0)

  @doc """
  The selection toolbar: how many groups are selected, a shortcut to select
  every group matching the active filter, and the accept/ignore/clear actions.

  Shown whenever there is something to act on -- either a group is already
  selected, or the band/search filter narrows the page to a subset a user
  would plausibly want to select in bulk without touching every checkbox.

  `matching_count` is how many groups the active band *and* search actually
  match, library-wide -- not `band_counts/1`'s total, which knows nothing
  about the search box and would offer to "select all" a number the search
  has already narrowed past. The caller computes it with the same
  `SelectionScope` predicate `select_all_matching/1` itself uses, so the two
  can never disagree.
  """
  attr :count, :integer, required: true
  attr :matching_count, :integer, required: true
  attr :page_count, :integer, default: 0
  attr :band, :atom, default: :all

  def bulk_bar(assigns) do
    ~H"""
    <div
      class="alert alert-info shadow-sm flex items-center justify-between flex-wrap gap-3 py-2.5 px-4"
      id="bulk-bar"
    >
      <div class="flex items-center gap-2.5 flex-wrap">
        <.icon name="hero-check-circle" class="w-5 h-5 shrink-0" />
        <span class="font-medium text-sm">{@count} group(s) selected</span>

        <button
          :if={@page_count > 0 and @count < @page_count}
          id="select-current-page"
          class="btn btn-xs btn-ghost underline hover:no-underline"
          phx-click="select_current_page"
        >
          Select page ({@page_count})
        </button>

        <button
          :if={@matching_count > @count}
          id="select-all-matching"
          class="btn btn-xs btn-ghost underline hover:no-underline"
          phx-click="select_all_matching"
        >
          Select all {@matching_count} matching this filter
        </button>
      </div>

      <div class="flex items-center gap-2 ml-auto flex-wrap">
        <%= if @band == :ignored do %>
          <button
            id="restore-selected"
            class="btn btn-sm btn-primary"
            disabled={@count == 0}
            phx-click="restore_selected"
          >
            <.icon name="hero-arrow-uturn-left" class="w-4 h-4 mr-1" /> Restore {@count}
          </button>
          <button id="clear-selection" class="btn btn-sm btn-ghost" phx-click="clear_selection">
            Clear
          </button>
        <% else %>
          <button
            id="accept-selected"
            class="btn btn-sm btn-primary"
            disabled={@count == 0}
            phx-click="accept_selected"
          >
            <.icon name="hero-check" class="w-4 h-4 mr-1" /> Accept {@count}
          </button>
          <button
            id="rematch-selected"
            class="btn btn-sm btn-outline"
            disabled={@count == 0}
            phx-click="rematch_selected"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Re-match
          </button>
          <button
            id="ignore-selected"
            class="btn btn-sm btn-ghost"
            disabled={@count == 0}
            phx-click="ignore_selected"
          >
            Ignore
          </button>
          <button id="clear-selection" class="btn btn-sm btn-ghost" phx-click="clear_selection">
            Clear
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  One group row: a checkbox, the collapsed summary, and (when expanded) its
  member files.

  `expanded` is per-row (any number of rows can be open at once -- a settled
  group starts closed, an unsettled one starts open). `members` is not: only
  the one group most recently clicked ever gets `@streams.members`, every
  other open row is passed `[]` so its `<ul>` renders with nothing in it
  until it, too, is clicked. That is what keeps the page bounded even when
  every group on it is unsettled and auto-expanded.
  """
  attr :id, :string, required: true
  attr :group, :map, required: true
  attr :band, :atom, required: true
  attr :selected, :boolean, required: true
  attr :expanded, :boolean, required: true
  attr :members, :any, required: true

  def group_row(assigns) do
    ~H"""
    <div id={@id} class="p-3.5 sm:p-4 hover:bg-base-200/40 transition-colors flex flex-col gap-2">
      <div class="flex items-center gap-3 min-w-0">
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm shrink-0"
          checked={@selected}
          aria-label={"Select #{@group.display_title}"}
          phx-click="toggle_group"
          phx-value-id={@group.id}
        />

        <button
          type="button"
          id={"group-toggle-#{@group.id}"}
          class="flex-1 flex items-center gap-2 min-w-0 text-left cursor-pointer group/title"
          phx-click="expand_group"
          phx-value-id={@group.id}
        >
          <.icon
            name={if(@expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
            class="w-4 h-4 opacity-50 group-hover/title:opacity-100 transition-opacity shrink-0"
          />
          <span class="font-semibold text-sm truncate group-hover/title:text-primary transition-colors">
            {@group.display_title}
          </span>
          <span class="badge badge-ghost badge-sm shrink-0 font-normal">
            {@group.file_count} file{if @group.file_count == 1, do: "", else: "s"}
          </span>
          <span :if={season_label(@group)} class="badge badge-ghost badge-sm shrink-0">
            {season_label(@group)}
          </span>
        </button>

        <span class={["badge badge-sm shrink-0 font-medium", band_class(@band)]}>
          {band_label(@band)}
        </span>
      </div>

      <div class="pl-7 sm:pl-9 flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-2 flex-wrap min-w-0 text-xs text-base-content/70">
          <span class="font-medium text-base-content/90 truncate max-w-md">
            {suggestion_line(@group)}
          </span>
          <span
            :if={evidence_label(@group.evidence)}
            class="badge badge-ghost badge-xs text-base-content/60"
          >
            {evidence_label(@group.evidence)}
          </span>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <button
            id={"change-match-#{@group.id}"}
            class="btn btn-xs btn-outline"
            phx-click="open_match_search"
            phx-value-id={@group.id}
          >
            <.icon name="hero-pencil-square" class="w-3.5 h-3.5 mr-1 opacity-70" />
            {if @band == :no_match, do: "Identify", else: "Change match"}
          </button>
          <button
            :if={@band == :no_match}
            id={"create-local-#{@group.id}"}
            class="btn btn-xs btn-outline"
            phx-click="create_local_show"
            phx-value-id={@group.id}
          >
            <.icon name="hero-folder-plus" class="w-3.5 h-3.5 mr-1 opacity-70" />
            Create show from folder
          </button>
        </div>
      </div>

      <div :if={@expanded} class="pl-7 sm:pl-9 pt-1">
        <ul
          id={"members-#{@group.id}"}
          phx-update="stream"
          class="bg-base-200/50 rounded-xl p-3 divide-y divide-base-200/60 max-h-80 overflow-y-auto"
        >
          <li
            :for={{member_dom_id, member} <- @members}
            id={member_dom_id}
            class="py-2 first:pt-0 last:pb-0 flex flex-col sm:flex-row sm:items-center justify-between gap-2.5"
          >
            <div class="flex items-center gap-2.5 min-w-0 flex-1">
              <.icon name="hero-film" class="w-4 h-4 shrink-0 opacity-40 text-base-content" />
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2 flex-wrap min-w-0">
                  <span
                    id={"member-#{member.media_file.id}"}
                    class="font-mono font-medium text-xs text-base-content/90 truncate"
                    title={member.media_file.relative_path}
                  >
                    {member_filename(member)}
                  </span>
                  <span
                    :if={@group.media_type != "movie"}
                    class={[
                      "badge badge-xs font-mono font-medium shrink-0",
                      if(member_episode_badge(member) != "No episode",
                        do: "badge-primary/20 text-primary",
                        else: "badge-warning/20 text-warning"
                      )
                    ]}
                  >
                    {member_episode_badge(member)}
                  </span>
                </div>
                <p
                  :if={member_folder(member)}
                  class="text-[11px] font-mono text-base-content/50 truncate mt-0.5"
                >
                  {member_folder(member)}
                </p>
              </div>
            </div>

            <form
              :if={@group.media_type != "movie"}
              id={"member-form-#{member.media_file.id}"}
              phx-change="update_member_episode"
              phx-submit="update_member_episode"
              class="flex items-center gap-1.5 shrink-0 self-end sm:self-center"
            >
              <input type="hidden" name="file_id" value={member.media_file.id} />
              <div class="join items-center bg-base-100 rounded-lg border border-base-300 shadow-xs">
                <span class="join-item px-1.5 text-[11px] text-base-content/60 font-mono font-bold">
                  S
                </span>
                <input
                  type="number"
                  name="season"
                  value={member_season(member)}
                  placeholder="--"
                  min="0"
                  max="999"
                  phx-debounce="400"
                  class="join-item input input-xs w-12 text-center font-mono border-0 focus:outline-none"
                  aria-label={"Season for #{member_filename(member)}"}
                />
                <span class="join-item px-1.5 text-[11px] text-base-content/60 font-mono font-bold">
                  E
                </span>
                <input
                  type="number"
                  name="episode"
                  value={member_episode(member)}
                  placeholder="--"
                  min="0"
                  max="9999"
                  phx-debounce="400"
                  class="join-item input input-xs w-14 text-center font-mono border-0 focus:outline-none"
                  aria-label={"Episode for #{member_filename(member)}"}
                />
              </div>
            </form>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  One row on the Ignored view.
  """
  attr :id, :string, required: true
  attr :group, :map, required: true
  attr :selected, :boolean, default: false

  def ignored_group_row(assigns) do
    ~H"""
    <div
      id={@id}
      class="p-3.5 sm:p-4 hover:bg-base-200/40 transition-colors flex items-center justify-between gap-3"
    >
      <div class="flex items-center gap-3 min-w-0 flex-1">
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm shrink-0"
          checked={@selected}
          aria-label={"Select #{@group.display_title}"}
          phx-click="toggle_group"
          phx-value-id={@group.id}
        />

        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <span class="font-semibold text-sm truncate opacity-70">{@group.display_title}</span>
            <span class="badge badge-ghost badge-sm shrink-0">{@group.file_count} files</span>
            <span :if={season_label(@group)} class="badge badge-ghost badge-sm shrink-0">
              {season_label(@group)}
            </span>
          </div>
          <p class="text-xs text-base-content/50 truncate mt-0.5">{suggestion_line(@group)}</p>
        </div>
      </div>

      <button
        id={"restore-#{@group.id}"}
        class="btn btn-xs btn-outline shrink-0"
        phx-click="restore_group"
        phx-value-id={@group.id}
      >
        <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5 mr-1" /> Restore
      </button>
    </div>
    """
  end

  @doc """
  The "Change match" / "Identify" search modal.

  `state` is `ImportMediaLive.Index`'s `@match_search` assign -- nil when
  closed, otherwise `%{group_id:, media_type:, query:, results:, searching:,
  error:}`. Selecting a result submits `provider_id` *and* `provider`
  together (a result's own provider tag, `:tvdb` or `:metadata_relay`/etc for
  TMDB), which is what lets the handler tell two providers' ids apart rather
  than trusting `provider_id` alone to be unique.
  """
  attr :state, :any, default: nil

  def match_search_modal(assigns) do
    ~H"""
    <.modal id="match-search-modal" show={not is_nil(@state)} on_cancel="close_match_search">
      <:title>
        <div class="flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="w-5 h-5 text-primary" />
          <span>Change match</span>
        </div>
      </:title>

      <form phx-change="match_search_query" id="match-search-form" class="mt-3">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="w-4 h-4 absolute left-3.5 top-1/2 -translate-y-1/2 opacity-50"
          />
          <input
            type="text"
            name="q"
            value={@state && @state.query}
            placeholder="Search by title…"
            phx-debounce="300"
            class="input input-bordered w-full pl-10"
          />
        </div>
      </form>

      <div
        :if={@state}
        class="mt-4 flex flex-col gap-1.5 max-h-96 overflow-y-auto"
        id="match-results"
      >
        <div :if={@state.searching} class="flex justify-center py-8">
          <span class="loading loading-spinner loading-md text-primary"></span>
        </div>

        <div :if={!@state.searching}>
          <div :if={@state.error} class="alert alert-error text-xs py-2 mb-2">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
            <span>{@state.error}</span>
          </div>

          <div
            :if={!@state.error && @state.results == []}
            class="text-sm text-base-content/60 text-center py-10"
          >
            <.icon name="hero-film" class="w-8 h-8 mx-auto mb-2 opacity-30" />
            <p>No results found.</p>
          </div>

          <button
            :for={result <- @state.results}
            type="button"
            id={"match-result-#{result.provider_id}-#{result.provider}"}
            class="flex items-center gap-3.5 p-2.5 rounded-xl hover:bg-base-200 text-left w-full transition-colors border border-transparent hover:border-base-300"
            phx-click="select_match"
            phx-value-provider_id={result.provider_id}
            phx-value-provider={result.provider}
          >
            <img
              :if={result.poster_path}
              src={ImageUrl.image_url(result.poster_path, "w92")}
              class="w-12 h-16 object-cover rounded-lg shrink-0 shadow-sm"
            />
            <div
              :if={!result.poster_path}
              class="w-12 h-16 bg-base-300 rounded-lg flex items-center justify-center shrink-0"
            >
              <.icon name="hero-film" class="w-6 h-6 opacity-30" />
            </div>
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm truncate">{result.title}</p>
              <p class="text-xs text-base-content/60 flex items-center gap-1.5 mt-1">
                <span :if={result.year} class="font-mono">{result.year}</span>
                <span class="badge badge-ghost badge-xs font-medium">
                  {media_type_label(result.media_type)}
                </span>
              </p>
            </div>
            <.icon name="hero-chevron-right" class="w-4 h-4 opacity-40 shrink-0" />
          </button>
        </div>
      </div>

      <:actions>
        <button class="btn btn-ghost" phx-click="close_match_search">Cancel</button>
      </:actions>
    </.modal>
    """
  end

  defp media_type_label(:tv_show), do: "TV Show"
  defp media_type_label(:movie), do: "Movie"
  defp media_type_label(_), do: "Unknown"

  defp band_class(:ready), do: "badge-success"
  defp band_class(:needs_attention), do: "badge-warning"
  defp band_class(:no_match), do: "badge-error"

  defp band_label(:ready), do: "ready"
  defp band_label(:needs_attention), do: "needs attention"
  defp band_label(:no_match), do: "no match"

  defp season_label(%{media_type: "movie"}), do: nil

  defp season_label(group) do
    case Mydia.Library.ImportGroup.season_span(group) do
      [] -> nil
      [one] -> "S#{one}"
      seasons -> "S#{List.first(seasons)}–S#{List.last(seasons)}"
    end
  end

  defp suggestion_line(%{provider_id: nil}), do: "No provider match"

  defp suggestion_line(group) do
    year = if group.suggested_year, do: " (#{group.suggested_year})", else: ""
    "→ #{group.suggested_title}#{year}"
  end

  # The human-readable side of `Mydia.ImportGroups`'s `evidence` column: what
  # actually earned a group its suggested match, not just the confidence
  # number. This is the design's own accountability mechanism for a fixed
  # 0.85 threshold -- "the evidence label in the UI is what keeps this
  # honest" -- so it has to render, not just get computed and stored.
  #
  # Only `"none"`, `"exact_title"` and `"fuzzy"` are emitted by
  # `ImportGroups`'s `evidence_kind/2` today; `"external_id"` and `"reused"`
  # are the spec's own table for a future matcher pass, and `"manual"` is
  # `ImportGroups.change_match/2`'s own kind for a human-picked match. Every
  # other kind (including one this module has never heard of) falls through
  # to the raw string rather than crashing, so a future evidence kind renders
  # as *something* immediately, with no LiveView deploy required just to stop
  # erroring.
  defp evidence_label(%{"kind" => "external_id"}), do: "tvdb id in folder name"
  defp evidence_label(%{"kind" => "reused"}), do: "matched before"
  defp evidence_label(%{"kind" => "exact_title"}), do: "exact title match"
  defp evidence_label(%{"kind" => "manual"}), do: "manually matched"

  defp evidence_label(%{"kind" => "fuzzy", "candidates" => n}) when is_integer(n) and n > 0,
    do: "fuzzy title, #{n} candidate#{if n == 1, do: "", else: "s"}"

  defp evidence_label(%{"kind" => "fuzzy"}), do: "fuzzy title match"
  # "no match" is already said by suggestion_line/1 above; a second badge
  # repeating it would be noise, not evidence.
  defp evidence_label(%{"kind" => "none"}), do: nil
  defp evidence_label(%{"kind" => kind}) when is_binary(kind), do: kind
  defp evidence_label(_), do: nil

  defp member_filename(member) do
    Path.basename(member.media_file.relative_path || member.media_file.path || "")
  end

  defp member_folder(member) do
    dir = Path.dirname(member.media_file.relative_path || member.media_file.path || "")
    if dir in [".", "", "/"], do: nil, else: dir
  end

  defp member_season(%{candidate: %{parsed_info: %{} = info}}) do
    case Map.get(info, "season") || Map.get(info, :season) do
      s when is_integer(s) -> s
      _ -> nil
    end
  end

  defp member_season(_), do: nil

  defp member_episode(%{candidate: %{parsed_info: %{} = info}}) do
    episodes = Map.get(info, "episodes") || Map.get(info, :episodes) || []

    case episodes do
      [ep | _] when is_integer(ep) -> ep
      _ -> nil
    end
  end

  defp member_episode(_), do: nil

  defp member_episode_badge(member) do
    season = member_season(member)
    episode = member_episode(member)

    cond do
      season != nil and episode != nil ->
        "S#{String.pad_leading(to_string(season), 2, "0")}E#{String.pad_leading(to_string(episode), 2, "0")}"

      season != nil ->
        "S#{String.pad_leading(to_string(season), 2, "0")}"

      episode != nil ->
        "E#{String.pad_leading(to_string(episode), 2, "0")}"

      true ->
        "No episode"
    end
  end
end
