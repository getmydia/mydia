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

  ## Helper Functions

  defp format_file_size(size) when size < 1024, do: "#{size} B"
  defp format_file_size(size) when size < 1_048_576, do: "#{Float.round(size / 1024, 1)} KB"

  defp format_file_size(size) when size < 1_073_741_824,
    do: "#{Float.round(size / 1_048_576, 1)} MB"

  defp format_file_size(size), do: "#{Float.round(size / 1_073_741_824, 1)} GB"
end
