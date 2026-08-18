defmodule MydiaWeb.ImportMediaLive.Components do
  @moduledoc """
  Reusable UI components for the grouped import review table.

  Each component renders from an `Mydia.Library.ImportGroup` row (or a page of
  them), never from a loaded collection of files: that is what keeps the page
  independent of how many files a group actually has.
  """

  use Phoenix.Component
  import MydiaWeb.CoreComponents

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
              {:no_match, "band-no-match", "No match"}
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
  """
  attr :count, :integer, required: true
  attr :band_total, :integer, required: true
  attr :mode, :atom, required: true

  def bulk_bar(assigns) do
    ~H"""
    <div class="alert alert-info flex-wrap gap-2" id="bulk-bar">
      <span>{@count} group(s) selected.</span>

      <button
        :if={@band_total > @count}
        id="select-all-matching"
        class="btn btn-xs btn-ghost"
        phx-click="select_all_matching"
      >
        Select all {@band_total} matching this filter
      </button>

      <div class="ml-auto flex gap-2">
        <button id="accept-selected" class="btn btn-sm btn-primary" phx-click="accept_selected">
          Accept {@count}
        </button>
        <button id="ignore-selected" class="btn btn-sm btn-ghost" phx-click="ignore_selected">
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

  `members` is the LiveView's whole `@streams.members` stream, shared across
  every row because only one group is ever expanded at a time
  (`expanded_group_id` is a single value on the socket). The `phx-update`
  container id is per-group, so LiveView discards the old member list's DOM
  the moment expansion moves to a different row.
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

      <p class="pl-10 text-sm opacity-70">
        {suggestion_line(@group)}
      </p>

      <ul :if={@expanded} id={"members-#{@group.id}"} phx-update="stream" class="pl-10 pt-2">
        <li :for={{member_dom_id, member} <- @members} id={member_dom_id} class="text-sm py-1">
          <span id={"member-#{member.media_file.id}"}>{member.media_file.relative_path}</span>
        </li>
      </ul>
    </div>
    """
  end

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
end
