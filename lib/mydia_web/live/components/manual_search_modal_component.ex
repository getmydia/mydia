defmodule MydiaWeb.Live.Components.ManualSearchModalComponent do
  @moduledoc """
  A reusable LiveComponent for manual metadata search modal.

  This component is shown when automatic parsing or matching fails, allowing
  the user to manually search for and select the correct metadata.

  ## Usage

      <.live_component
        module={MydiaWeb.Live.Components.ManualSearchModalComponent}
        id="manual-search-modal"
        show={@show_manual_search_modal}
        failed_title={@failed_release_title}
        search_query={@manual_search_query}
        matches={@metadata_matches}
        on_search="manual_search_submit"
        on_select="select_manual_match"
        on_cancel="close_manual_search_modal"
      />

  ## Events

  The component emits these events to the parent LiveView:

  - `on_search` - When user submits the search form. Includes `search_query` param.
  - `on_select` - When user clicks a match. Includes `match_id` and `media_type` params.
  - `on_cancel` - When user clicks Cancel button.
  """
  use MydiaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @show do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-4xl">
            <h3 class="font-bold text-lg mb-2">
              {gettext("Manual Search Required")}
            </h3>
            <p class="text-sm text-base-content/70 mb-4">
              {gettext("Could not automatically parse or find metadata for:")}
              <span class="font-semibold block mt-1 text-base-content">
                {@failed_title}
              </span>
            </p>
            <p class="text-sm text-base-content/70 mb-4">
              {gettext("Please search manually for the media:")}
            </p>
            <form phx-submit={@on_search} class="mb-4">
              <div class="flex gap-2">
                <input
                  type="text"
                  name="search_query"
                  value={@search_query}
                  placeholder={gettext("Enter media title to search...")}
                  class="input input-bordered flex-1"
                  phx-debounce="300"
                />
                <button type="submit" class="btn btn-primary">
                  <.icon name="hero-magnifying-glass" class="w-4 h-4" /> {pgettext("search", "Search")}
                </button>
              </div>
            </form>
            <%= if @matches != [] do %>
              <div class="divider text-sm">{gettext("Select a Match")}</div>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 max-h-[50vh] overflow-y-auto">
                <%= for match <- @matches do %>
                  <% is_selecting = @selecting_match_id == to_string(match.provider_id) %>
                  <% any_selecting = @selecting_match_id != nil %>
                  <div
                    class={[
                      "card transition-colors",
                      is_selecting && "bg-primary/20 ring-2 ring-primary",
                      !is_selecting && "bg-base-200 hover:bg-base-300",
                      any_selecting && !is_selecting && "opacity-50",
                      !any_selecting && "cursor-pointer"
                    ]}
                    phx-click={unless any_selecting, do: @on_select}
                    phx-value-match_id={match.provider_id}
                    phx-value-media_type={
                      if match.media_type == :tv_show, do: "tv_show", else: "movie"
                    }
                  >
                    <div class="card-body p-4">
                      <div class="flex gap-4">
                        <%= if is_selecting do %>
                          <div class="w-16 h-24 bg-base-300 rounded flex items-center justify-center">
                            <span class="loading loading-spinner loading-md text-primary"></span>
                          </div>
                        <% else %>
                          <%= if Map.get(match, :poster_path) do %>
                            <img
                              src={ImageUrl.image_url(match.poster_path, "w92")}
                              alt={match.title}
                              class="w-16 h-24 object-cover rounded"
                            />
                          <% else %>
                            <div class="w-16 h-24 bg-base-300 rounded flex items-center justify-center">
                              <.icon name="hero-film" class="w-8 h-8 text-base-content/30" />
                            </div>
                          <% end %>
                        <% end %>
                        <div class="flex-1 min-w-0">
                          <h4 class="font-semibold text-base line-clamp-2">
                            {match.title}
                          </h4>
                          <div class="flex gap-2 items-center mt-1">
                            <%= if Map.get(match, :release_date) || Map.get(match, :first_air_date) do %>
                              <p class="text-sm text-base-content/60">
                                {String.slice(match.release_date || match.first_air_date, 0..3)}
                              </p>
                            <% end %>
                            <span class="badge badge-sm badge-outline">
                              {if match.media_type == :tv_show,
                                do: gettext("TV Show"),
                                else: gettext("Movie")}
                            </span>
                            <%= if is_selecting do %>
                              <span class="badge badge-sm badge-primary">{gettext("Adding...")}</span>
                            <% end %>
                          </div>
                          <%= if Map.get(match, :overview) do %>
                            <p class="text-xs text-base-content/50 mt-2 line-clamp-2">
                              {match.overview}
                            </p>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
            <div class="modal-action">
              <button
                class="btn btn-ghost"
                phx-click={@on_cancel}
                disabled={@selecting_match_id != nil}
              >
                {gettext("Cancel")}
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:show, fn -> false end)
     |> assign_new(:failed_title, fn -> "" end)
     |> assign_new(:search_query, fn -> "" end)
     |> assign_new(:matches, fn -> [] end)
     |> assign_new(:selecting_match_id, fn -> nil end)}
  end
end
