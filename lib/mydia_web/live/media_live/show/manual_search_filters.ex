defmodule MydiaWeb.MediaLive.Show.ManualSearchFilters do
  @moduledoc """
  The filters bar of the manual search modal: quality, source, codec and
  minimum-seeders filters, the "Close after grabbing" toggle, and the sort
  order. `MydiaWeb.MediaLive.Show` handles its events.
  """
  use Phoenix.Component

  attr :quality_filter, :string, default: nil
  attr :source_filter, :string, default: nil
  attr :codec_filter, :string, default: nil
  attr :filter_options, :map, default: %{sources: [], codecs: []}
  attr :min_seeders, :integer, default: 0
  attr :close_after_grab, :boolean, default: false
  attr :sort_by, :atom, required: true

  def filters_bar(assigns) do
    ~H"""
    <div class="bg-base-200/50 border-b border-base-300 px-4 py-3">
      <div class="flex flex-wrap items-center gap-3">
        <form
          id="manual-search-filter-form"
          phx-change="filter_search"
          class="flex flex-wrap items-center gap-3"
        >
          <select name="quality" class="select select-bordered select-sm w-auto">
            <option value="" selected={is_nil(@quality_filter)}>All Quality</option>
            <option value="720p" selected={@quality_filter == "720p"}>720p</option>
            <option value="1080p" selected={@quality_filter == "1080p"}>1080p</option>
            <option value="2160p" selected={@quality_filter in ["2160p", "4k"]}>4K</option>
          </select>
          <select
            id="manual-search-source-filter"
            name="source"
            class="select select-bordered select-sm w-auto"
          >
            <option value="" selected={is_nil(@source_filter)}>All Sources</option>
            <option
              :for={source <- @filter_options.sources}
              value={source}
              selected={@source_filter == source}
            >
              {source}
            </option>
          </select>
          <select
            id="manual-search-codec-filter"
            name="codec"
            class="select select-bordered select-sm w-auto"
          >
            <option value="" selected={is_nil(@codec_filter)}>All Codecs</option>
            <option
              :for={codec <- @filter_options.codecs}
              value={codec}
              selected={@codec_filter == codec}
            >
              {codec}
            </option>
          </select>
          <div class="join">
            <span class="join-item btn btn-sm btn-ghost no-animation pointer-events-none">
              Min Seeds
            </span>
            <input
              type="number"
              name="min_seeders"
              value={@min_seeders}
              min="0"
              class="input input-bordered input-sm w-16 join-item"
              placeholder="0"
            />
          </div>
        </form>
        <div class="flex-1"></div>
        <label
          class="label cursor-pointer gap-2"
          id="close-after-grab-toggle"
          title="Close this dialog as soon as a release is grabbed"
        >
          <span class="label-text text-xs">Close after grabbing</span>
          <input
            type="checkbox"
            class="toggle toggle-sm toggle-primary"
            checked={@close_after_grab}
            phx-click="toggle_close_after_grab"
          />
        </label>
        <form id="manual-search-sort-form" phx-change="sort_search">
          <select name="sort_by" class="select select-bordered select-sm">
            <option value="quality" selected={@sort_by == :quality}>Best Score</option>
            <option value="seeders" selected={@sort_by == :seeders}>Most Seeds</option>
            <option value="size" selected={@sort_by == :size}>Largest</option>
            <option value="date" selected={@sort_by == :date}>Newest</option>
          </select>
        </form>
      </div>
    </div>
    """
  end
end
