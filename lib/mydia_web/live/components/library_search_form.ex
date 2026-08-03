defmodule MydiaWeb.Live.Components.LibrarySearchForm do
  @moduledoc """
  Inline search picker for matching downloads to local library items.

  Provides a search input with autocomplete dropdown showing local media items.
  Used in the Issues tab to manually match unmatched downloads.
  """
  use Phoenix.Component
  alias Mydia.Metadata.ImageUrl
  import MydiaWeb.CoreComponents

  attr :search_value, :string, default: ""
  attr :search_results, :list, default: []
  attr :on_search, :string, required: true
  attr :on_select, :string, required: true
  attr :download_id, :string, required: true
  attr :placeholder, :string, default: "Search library..."

  def library_search_form(assigns) do
    ~H"""
    <div class="relative mt-2">
      <form id={"library-search-form-#{@download_id}"} phx-change={@on_search}>
        <input type="hidden" name="download_id" value={@download_id} />
        <input
          type="text"
          name="library_search"
          value={@search_value}
          class="input input-bordered input-sm w-full"
          phx-debounce="300"
          autocomplete="off"
          placeholder={@placeholder}
        />
      </form>
      <%= if @search_results != [] do %>
        <div class="absolute z-10 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-lg max-h-48 overflow-y-auto">
          <%= for item <- @search_results do %>
            <button
              type="button"
              class="w-full text-left px-3 py-2 hover:bg-base-200 border-b border-base-300 last:border-b-0 flex gap-3 items-center"
              phx-click={@on_select}
              phx-value-download_id={@download_id}
              phx-value-media_item_id={item.id}
              phx-value-title={item.title}
              phx-value-type={item.type}
            >
              <%!-- MediaItem.metadata loads as a %MediaMetadata{}, which has no
              Access implementation — get_in/bracket syntax raises here. --%>
              <% poster_path = item.metadata && item.metadata.poster_path %>
              <%= if poster_path do %>
                <img
                  src={ImageUrl.image_url(poster_path, "w92")}
                  alt={item.title}
                  class="w-8 h-12 object-cover rounded flex-shrink-0"
                />
              <% else %>
                <div class="w-8 h-12 bg-base-300 rounded flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-film" class="w-4 h-4 text-base-content/30" />
                </div>
              <% end %>
              <div class="flex-1 min-w-0">
                <div class="font-medium text-sm line-clamp-1">{item.title}</div>
                <div class="flex gap-2 items-center mt-0.5">
                  <%= if item.year do %>
                    <span class="text-xs text-base-content/60">{item.year}</span>
                  <% end %>
                  <span class="badge badge-xs badge-outline">
                    {if item.type == "tv_show", do: "TV", else: "Movie"}
                  </span>
                </div>
              </div>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
