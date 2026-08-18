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
    <div class="flex items-center gap-2 flex-wrap">
      <button
        :for={path <- @library_paths}
        type="button"
        id={"library-picker-#{path.id}"}
        class={["btn btn-sm", if(path.id == @selected_id, do: "btn-primary", else: "btn-ghost")]}
        phx-click="select_library"
        phx-value-library_path_id={path.id}
      >
        {path.path}
        <span class="badge badge-sm">{Map.get(@counts, path.id, 0)}</span>
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
    <div class="flex items-center gap-2 flex-wrap">
      <div class="filter">
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
          class={["btn btn-sm gap-1.5", @band == band && "btn-active"]}
          phx-click="select_band"
          phx-value-band={band}
        >
          <input type="checkbox" class="checkbox checkbox-xs" checked={@band == band} tabindex="-1" />
          {label}
          <span class="badge badge-sm">{count_for(@counts, band)}</span>
        </label>
      </div>

      <form phx-change="search" id="import-search-form" class="ml-auto">
        <input
          type="text"
          name="q"
          value={@search}
          placeholder="Search folder…"
          phx-debounce="300"
          class="input input-sm input-bordered"
        />
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

  def bulk_bar(assigns) do
    ~H"""
    <div class="alert alert-info flex-wrap gap-2" id="bulk-bar">
      <span>{@count} group(s) selected.</span>

      <button
        :if={@matching_count > @count}
        id="select-all-matching"
        class="btn btn-xs btn-ghost"
        phx-click="select_all_matching"
      >
        Select all {@matching_count} matching this filter
      </button>

      <div class="ml-auto flex gap-2">
        <button
          id="accept-selected"
          class="btn btn-sm btn-primary"
          disabled={@count == 0}
          phx-click="accept_selected"
        >
          Accept {@count}
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
    <div id={@id} class="py-3">
      <div class="flex items-center gap-3">
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          checked={@selected}
          aria-label={"Select #{@group.display_title}"}
          phx-click="toggle_group"
          phx-value-id={@group.id}
        />

        <button
          type="button"
          id={"group-toggle-#{@group.id}"}
          class="flex-1 flex items-center gap-2 text-left"
          phx-click="expand_group"
          phx-value-id={@group.id}
        >
          <.icon
            name={if(@expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
            class="w-4 h-4 opacity-60"
          />
          <span class="font-semibold">{@group.display_title}</span>
          <span class="badge badge-sm">{@group.file_count} files</span>
          <span :if={season_label(@group)} class="badge badge-ghost badge-sm">
            {season_label(@group)}
          </span>
        </button>

        <span class={["badge badge-sm", band_class(@band)]}>{band_label(@band)}</span>
      </div>

      <p class="pl-10 text-sm opacity-70 flex items-center gap-2 flex-wrap">
        {suggestion_line(@group)}
        <span :if={evidence_label(@group.evidence)} class="badge badge-ghost badge-xs">
          {evidence_label(@group.evidence)}
        </span>
        <button
          id={"change-match-#{@group.id}"}
          class="btn btn-xs btn-outline"
          phx-click="open_match_search"
          phx-value-id={@group.id}
        >
          {if @band == :no_match, do: "Identify", else: "Change match"}
        </button>
        <button
          :if={@band == :no_match}
          id={"create-local-#{@group.id}"}
          class="btn btn-xs btn-outline"
          phx-click="create_local_show"
          phx-value-id={@group.id}
        >
          Create show from folder
        </button>
      </p>

      <ul :if={@expanded} id={"members-#{@group.id}"} phx-update="stream" class="pl-10 pt-2">
        <li :for={{member_dom_id, member} <- @members} id={member_dom_id} class="text-sm py-1">
          <span id={"member-#{member.media_file.id}"}>{member.media_file.relative_path}</span>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  One row on the Ignored view.

  Deliberately not a variant of `group_row/1`: an ignored group has nothing
  to select, accept, change or expand -- accept/ignore/change_match all
  refuse a non-"pending" group, and `SelectionScope`'s own query is hardcoded
  to `status == "pending"`, so a checkbox here would either do nothing or
  lie about what it does. The one thing this view offers is the way back.
  """
  attr :id, :string, required: true
  attr :group, :map, required: true

  def ignored_group_row(assigns) do
    ~H"""
    <div id={@id} class="py-3 flex items-center gap-3">
      <span class="flex-1 flex items-center gap-2 min-w-0">
        <span class="font-semibold truncate">{@group.display_title}</span>
        <span class="badge badge-sm">{@group.file_count} files</span>
        <span :if={season_label(@group)} class="badge badge-ghost badge-sm">
          {season_label(@group)}
        </span>
      </span>

      <p class="text-sm opacity-70 truncate">{suggestion_line(@group)}</p>

      <button
        id={"restore-#{@group.id}"}
        class="btn btn-xs btn-outline shrink-0"
        phx-click="restore_group"
        phx-value-id={@group.id}
      >
        Restore
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
      <:title>Change match</:title>

      <form phx-change="match_search_query" id="match-search-form">
        <input
          type="text"
          name="q"
          value={@state && @state.query}
          placeholder="Search by title…"
          phx-debounce="300"
          class="input input-bordered w-full"
        />
      </form>

      <div :if={@state} class="mt-4 flex flex-col gap-1 max-h-96 overflow-y-auto" id="match-results">
        <div :if={@state.searching} class="flex justify-center py-6">
          <span class="loading loading-spinner loading-md"></span>
        </div>

        <div :if={!@state.searching}>
          <p :if={@state.error} class="text-error text-sm py-2">{@state.error}</p>

          <p
            :if={!@state.error && @state.results == []}
            class="text-sm opacity-70 text-center py-6"
          >
            No results.
          </p>

          <button
            :for={result <- @state.results}
            type="button"
            id={"match-result-#{result.provider_id}-#{result.provider}"}
            class="flex items-center gap-3 p-2 rounded-lg hover:bg-base-200 text-left w-full"
            phx-click="select_match"
            phx-value-provider_id={result.provider_id}
            phx-value-provider={result.provider}
          >
            <img
              :if={result.poster_path}
              src={ImageUrl.image_url(result.poster_path, "w92")}
              class="w-10 h-14 object-cover rounded shrink-0"
            />
            <div
              :if={!result.poster_path}
              class="w-10 h-14 bg-base-300 rounded flex items-center justify-center shrink-0"
            >
              <.icon name="hero-film" class="w-5 h-5 opacity-40" />
            </div>
            <div class="flex-1 min-w-0">
              <p class="font-medium truncate">{result.title}</p>
              <p class="text-xs opacity-60 flex items-center gap-1.5">
                <span :if={result.year}>{result.year}</span>
                <span class="badge badge-ghost badge-xs">{media_type_label(result.media_type)}</span>
              </p>
            </div>
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
end
