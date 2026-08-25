defmodule MydiaWeb.CollectionComponents do
  @moduledoc """
  Reusable components for collection views.

  These components provide a consistent UI for displaying and managing
  collections (both manual and smart).
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  alias Mydia.Collections.SmartRules

  @doc """
  Renders a grid of collections.

  ## Attributes

    * `:id` - Required. The DOM id for the grid container.
    * `:collections` - Required. The stream of collections to display.
    * `:class` - Additional CSS classes for the grid container.

  ## Slots

    * `:collection` - Required. Slot for rendering each collection.
  """
  attr :id, :string, required: true
  attr :collections, :any, required: true
  attr :class, :string, default: nil

  slot :collection, required: true

  def collection_grid(assigns) do
    ~H"""
    <div
      id={@id}
      phx-update="stream"
      class={[
        "grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3 md:gap-4 pb-6 md:pb-8",
        @class
      ]}
    >
      <div :for={{id, collection} <- @collections} id={id}>
        {render_slot(@collection, collection)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a list of collections.

  ## Attributes

    * `:id` - Required. The DOM id for the list container.
    * `:collections` - Required. The stream of collections to display.
    * `:class` - Additional CSS classes for the list container.

  ## Slots

    * `:collection` - Required. Slot for rendering each collection row.
  """
  attr :id, :string, required: true
  attr :collections, :any, required: true
  attr :class, :string, default: nil

  slot :collection, required: true

  def collection_list(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-lg overflow-hidden", @class]}>
      <%!-- List View Header --%>
      <div class="flex items-center bg-base-200 font-semibold text-sm px-4 py-3 border-b border-base-300">
        <div class="w-14 flex-shrink-0"></div>
        <div class="flex-1 min-w-0">Name</div>
        <div class="w-24 hidden md:block text-center flex-shrink-0">Type</div>
        <div class="w-24 hidden lg:block text-center flex-shrink-0">Items</div>
        <div class="w-24 hidden lg:block text-center flex-shrink-0">Visibility</div>
      </div>

      <%!-- List Items --%>
      <div id={@id} phx-update="stream">
        <div :for={{id, collection} <- @collections} id={id} class="contents">
          {render_slot(@collection, collection)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a card for a collection in grid view.

  ## Attributes

    * `:collection` - Required. The collection to display.
    * `:href` - Required. The link to the collection's detail page.
    * `:item_count` - The number of items in the collection. Defaults to 0.
    * `:poster_paths` - List of TMDB poster paths for creating a collage. Defaults to empty list.
    * `:on_play` - Optional. Event name to trigger when Play All is clicked.
  """
  attr :collection, :map, required: true
  attr :href, :string, required: true
  attr :item_count, :integer, default: 0
  attr :poster_paths, :list, default: []
  attr :on_play, :string, default: nil
  attr :can_edit, :boolean, default: false

  def collection_card(assigns) do
    ~H"""
    <div class="relative group">
      <div class="card bg-base-100 shadow-lg hover:shadow-xl transition-shadow duration-200 overflow-hidden">
        <.link navigate={@href}>
          <figure class="relative aspect-[2/3] overflow-hidden bg-base-300">
            <.poster_collage poster_paths={@poster_paths} collection_type={@collection.type} />
            <%!-- Type badge --%>
            <div class={[
              "badge badge-sm absolute top-2 right-2 z-10 shadow-md gap-1",
              type_badge_class(@collection.type)
            ]}>
              <.icon name={type_icon(@collection.type)} class="w-3 h-3" />
              {type_label(@collection.type)}
            </div>
            <%!-- System badge --%>
            <%= if @collection.is_system do %>
              <div class="badge badge-ghost badge-sm absolute top-2 left-2 z-10 shadow-md gap-1">
                <.icon name="hero-star" class="w-3 h-3" />
              </div>
            <% end %>
          </figure>
        </.link>
        <%!-- Action buttons (appear on hover) --%>
        <div class="absolute bottom-14 right-2 flex flex-col gap-1 opacity-0 group-hover:opacity-100 transition-opacity duration-200 z-20">
          <%!-- Play button --%>
          <%= if @on_play && @item_count > 0 do %>
            <button
              type="button"
              phx-click={@on_play}
              phx-value-id={@collection.id}
              class="btn btn-circle btn-sm btn-primary shadow-lg"
              title="Play All"
            >
              <.icon name="hero-play-solid" class="w-4 h-4" />
            </button>
          <% end %>
          <%!-- Edit button (non-system collections only) --%>
          <%= if @can_edit and not @collection.is_system do %>
            <.link
              navigate={~p"/collections/#{@collection.id}?edit=true"}
              class="btn btn-circle btn-sm btn-ghost bg-base-100/90 shadow-lg"
              title="Edit Collection"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </.link>
          <% end %>
        </div>
        <div class="card-body p-3">
          <h3 class="card-title text-sm line-clamp-2" title={@collection.name}>
            {@collection.name}
          </h3>
          <div class="flex items-center justify-between gap-2">
            <span class="text-xs text-base-content/70">
              {@item_count} {if @item_count == 1, do: "item", else: "items"}
            </span>
            <%= if @collection.visibility == "shared" do %>
              <span class="badge badge-xs badge-outline gap-1">
                <.icon name="hero-globe-alt" class="w-3 h-3" /> Shared
              </span>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Renders a poster collage from multiple poster paths.
  # Displays:
  # - 4 posters: 2x2 grid
  # - 3 posters: 1 large + 2 small on right
  # - 2 posters: side by side
  # - 1 poster: full size
  # - 0 posters: placeholder icon
  attr :poster_paths, :list, required: true
  attr :collection_type, :string, default: "manual"

  defp poster_collage(%{poster_paths: []} = assigns) do
    ~H"""
    <div class="w-full h-full flex flex-col items-center justify-center bg-gradient-to-br from-base-200 to-base-300 group-hover:scale-105 transition-transform duration-300">
      <.icon
        name={if @collection_type == "smart", do: "hero-sparkles", else: "hero-folder"}
        class="w-16 h-16 text-base-content/20"
      />
    </div>
    """
  end

  defp poster_collage(%{poster_paths: [path]} = assigns) do
    assigns = assign(assigns, :url, tmdb_poster_url(path))

    ~H"""
    <img
      src={@url}
      alt="Collection poster"
      class="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
      loading="lazy"
    />
    """
  end

  defp poster_collage(%{poster_paths: [path1, path2]} = assigns) do
    assigns =
      assigns
      |> assign(:url1, tmdb_poster_url(path1))
      |> assign(:url2, tmdb_poster_url(path2))

    ~H"""
    <div class="grid grid-cols-2 w-full h-full group-hover:scale-105 transition-transform duration-300">
      <img src={@url1} alt="" class="w-full h-full object-cover" loading="lazy" />
      <img src={@url2} alt="" class="w-full h-full object-cover" loading="lazy" />
    </div>
    """
  end

  defp poster_collage(%{poster_paths: [path1, path2, path3]} = assigns) do
    assigns =
      assigns
      |> assign(:url1, tmdb_poster_url(path1))
      |> assign(:url2, tmdb_poster_url(path2))
      |> assign(:url3, tmdb_poster_url(path3))

    ~H"""
    <div class="grid grid-cols-2 w-full h-full group-hover:scale-105 transition-transform duration-300">
      <img src={@url1} alt="" class="w-full h-full object-cover row-span-2" loading="lazy" />
      <div class="flex flex-col">
        <img src={@url2} alt="" class="w-full h-1/2 object-cover" loading="lazy" />
        <img src={@url3} alt="" class="w-full h-1/2 object-cover" loading="lazy" />
      </div>
    </div>
    """
  end

  defp poster_collage(%{poster_paths: paths} = assigns) when length(paths) >= 4 do
    [path1, path2, path3, path4 | _] = paths

    assigns =
      assigns
      |> assign(:url1, tmdb_poster_url(path1))
      |> assign(:url2, tmdb_poster_url(path2))
      |> assign(:url3, tmdb_poster_url(path3))
      |> assign(:url4, tmdb_poster_url(path4))

    ~H"""
    <div class="grid grid-cols-2 grid-rows-2 w-full h-full group-hover:scale-105 transition-transform duration-300">
      <img src={@url1} alt="" class="w-full h-full object-cover" loading="lazy" />
      <img src={@url2} alt="" class="w-full h-full object-cover" loading="lazy" />
      <img src={@url3} alt="" class="w-full h-full object-cover" loading="lazy" />
      <img src={@url4} alt="" class="w-full h-full object-cover" loading="lazy" />
    </div>
    """
  end

  defp tmdb_poster_url(path), do: Mydia.Metadata.ImageUrl.poster_url(path, "w342")

  # Small poster collage for list view rows (2x2 grid in a small thumbnail)
  attr :poster_paths, :list, required: true
  attr :collection_type, :string, default: "manual"

  defp row_poster_collage(%{poster_paths: []} = assigns) do
    ~H"""
    <div class="w-10 h-14 rounded shadow-sm bg-base-300 flex items-center justify-center">
      <.icon
        name={if @collection_type == "smart", do: "hero-sparkles", else: "hero-folder"}
        class="w-5 h-5 text-base-content/30"
      />
    </div>
    """
  end

  defp row_poster_collage(%{poster_paths: [path]} = assigns) do
    assigns = assign(assigns, :url, tmdb_poster_url(path))

    ~H"""
    <img
      src={@url}
      alt=""
      loading="lazy"
      class="w-10 h-14 rounded shadow-sm object-cover bg-base-300"
    />
    """
  end

  defp row_poster_collage(%{poster_paths: paths} = assigns) do
    # Take up to 4 posters for a 2x2 mini grid
    urls = Enum.take(paths, 4) |> Enum.map(&tmdb_poster_url/1)
    assigns = assign(assigns, :urls, urls)

    ~H"""
    <div class="w-10 h-14 rounded shadow-sm overflow-hidden bg-base-300 grid grid-cols-2 grid-rows-2">
      <img :for={url <- @urls} src={url} alt="" loading="lazy" class="w-full h-full object-cover" />
    </div>
    """
  end

  @doc """
  Renders a row for a collection in list view.

  ## Attributes

    * `:collection` - Required. The collection to display.
    * `:href` - Required. The link to the collection's detail page.
    * `:item_count` - The number of items in the collection. Defaults to 0.
    * `:poster_paths` - List of TMDB poster paths for creating a collage. Defaults to empty list.
    * `:on_play` - Optional. Event name to trigger when Play All is clicked.
  """
  attr :collection, :map, required: true
  attr :href, :string, required: true
  attr :item_count, :integer, default: 0
  attr :poster_paths, :list, default: []
  attr :on_play, :string, default: nil
  attr :can_edit, :boolean, default: false

  def collection_row(assigns) do
    ~H"""
    <div class="flex items-center px-4 py-3 hover:bg-base-200/50 border-b border-base-200 last:border-b-0 odd:bg-base-100 even:bg-base-200/30 transition-colors">
      <%!-- Icon/Poster column --%>
      <div class="w-14 flex-shrink-0">
        <.link navigate={@href} class="block w-10">
          <.row_poster_collage poster_paths={@poster_paths} collection_type={@collection.type} />
        </.link>
      </div>
      <%!-- Name column --%>
      <div class="flex-1 min-w-0 pr-4">
        <div class="flex items-center gap-2">
          <.link
            navigate={@href}
            class="font-medium hover:text-primary transition-colors line-clamp-1"
          >
            {@collection.name}
          </.link>
          <%= if @collection.is_system do %>
            <span class="badge badge-xs badge-ghost">
              <.icon name="hero-star" class="w-3 h-3" />
            </span>
          <% end %>
        </div>
        <%= if @collection.description do %>
          <div class="text-sm text-base-content/60 line-clamp-1">
            {@collection.description}
          </div>
        <% end %>
      </div>
      <%!-- Type column --%>
      <div class="w-24 hidden md:flex justify-center flex-shrink-0">
        <span class={["badge badge-sm gap-1", type_badge_class(@collection.type)]}>
          <.icon name={type_icon(@collection.type)} class="w-3 h-3" />
          {type_label(@collection.type)}
        </span>
      </div>
      <%!-- Items column --%>
      <div class="w-24 hidden lg:block text-center text-base-content/70 flex-shrink-0">
        {@item_count}
      </div>
      <%!-- Visibility column --%>
      <div class="w-24 hidden lg:flex justify-center flex-shrink-0">
        <%= if @collection.visibility == "shared" do %>
          <span class="badge badge-sm badge-outline gap-1">
            <.icon name="hero-globe-alt" class="w-3 h-3" /> Shared
          </span>
        <% else %>
          <span class="badge badge-sm badge-ghost gap-1">
            <.icon name="hero-lock-closed" class="w-3 h-3" /> Private
          </span>
        <% end %>
      </div>
      <%!-- Actions column --%>
      <div class="w-20 flex justify-end gap-1 flex-shrink-0">
        <%!-- Play button --%>
        <%= if @on_play && @item_count > 0 do %>
          <button
            type="button"
            phx-click={@on_play}
            phx-value-id={@collection.id}
            class="btn btn-circle btn-sm btn-ghost"
            title="Play All"
          >
            <.icon name="hero-play-solid" class="w-4 h-4" />
          </button>
        <% end %>
        <%!-- Edit button (non-system collections only) --%>
        <%= if @can_edit and not @collection.is_system do %>
          <.link
            navigate={~p"/collections/#{@collection.id}?edit=true"}
            class="btn btn-circle btn-sm btn-ghost"
            title="Edit Collection"
          >
            <.icon name="hero-pencil" class="w-4 h-4" />
          </.link>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Renders a type selector toggle (Manual/Smart).

  ## Attributes

    * `:selected` - The currently selected type ("manual" or "smart").
    * `:name` - The form field name. Defaults to "type".
    * `:disabled` - Whether the selector is disabled.
  """
  attr :selected, :string, default: "manual"
  attr :name, :string, default: "type"
  attr :disabled, :boolean, default: false

  def type_selector(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <label class="label">
        <span class="label-text font-medium">Collection Type</span>
      </label>
      <div class="flex gap-2">
        <label class={[
          "flex-1 flex items-center gap-3 p-4 rounded-lg border-2 cursor-pointer transition-all",
          @selected == "manual" && "border-primary bg-primary/10",
          @selected != "manual" && "border-base-300 hover:border-primary/50",
          @disabled && "opacity-50 cursor-not-allowed"
        ]}>
          <input
            type="radio"
            name={@name}
            value="manual"
            class="radio radio-primary"
            checked={@selected == "manual"}
            disabled={@disabled}
          />
          <div>
            <div class="flex items-center gap-2 font-medium">
              <.icon name="hero-folder" class="w-5 h-5" /> Manual
            </div>
            <div class="text-sm text-base-content/60">
              Curate items by hand, drag to reorder
            </div>
          </div>
        </label>

        <label class={[
          "flex-1 flex items-center gap-3 p-4 rounded-lg border-2 cursor-pointer transition-all",
          @selected == "smart" && "border-secondary bg-secondary/10",
          @selected != "smart" && "border-base-300 hover:border-secondary/50",
          @disabled && "opacity-50 cursor-not-allowed"
        ]}>
          <input
            type="radio"
            name={@name}
            value="smart"
            class="radio radio-secondary"
            checked={@selected == "smart"}
            disabled={@disabled}
          />
          <div>
            <div class="flex items-center gap-2 font-medium">
              <.icon name="hero-sparkles" class="w-5 h-5" /> Smart
            </div>
            <div class="text-sm text-base-content/60">
              Auto-populate based on filter rules
            </div>
          </div>
        </label>
      </div>
    </div>
    """
  end

  @doc """
  Renders a single smart rule condition row.

  ## Attributes

    * `:index` - Required. The index of this condition in the list.
    * `:condition` - Required. The condition map with field, operator, value.
    * `:removable` - Whether the condition can be removed. Defaults to true.
  """
  attr :index, :integer, required: true
  attr :condition, :map, required: true
  attr :removable, :boolean, default: true

  def rule_condition(assigns) do
    ~H"""
    <div class="flex items-center gap-2 p-3 bg-base-200 rounded-lg">
      <%!-- Field selector --%>
      <select
        name={"conditions[#{@index}][field]"}
        class="select select-sm select-bordered flex-1 min-w-0"
        value={@condition["field"]}
      >
        <option value="">Select field...</option>
        <optgroup label="Basic">
          <option value="category" selected={@condition["field"] == "category"}>Category</option>
          <option value="type" selected={@condition["field"] == "type"}>Type</option>
          <option value="year" selected={@condition["field"] == "year"}>Year</option>
          <option value="title" selected={@condition["field"] == "title"}>Title</option>
          <option value="monitored" selected={@condition["field"] == "monitored"}>Monitored</option>
        </optgroup>
        <optgroup label="Metadata">
          <option
            value="metadata.vote_average"
            selected={@condition["field"] == "metadata.vote_average"}
          >
            Rating
          </option>
          <option value="metadata.genres" selected={@condition["field"] == "metadata.genres"}>
            Genre
          </option>
          <option
            value="metadata.original_language"
            selected={@condition["field"] == "metadata.original_language"}
          >
            Language
          </option>
          <option value="metadata.status" selected={@condition["field"] == "metadata.status"}>
            Status
          </option>
        </optgroup>
        <optgroup label="Dates">
          <option value="inserted_at" selected={@condition["field"] == "inserted_at"}>
            Date Added
          </option>
        </optgroup>
      </select>

      <%!-- Operator selector --%>
      <select
        name={"conditions[#{@index}][operator]"}
        class="select select-sm select-bordered w-32"
        value={@condition["operator"]}
      >
        <option value="eq" selected={@condition["operator"] == "eq"}>equals</option>
        <option value="gt" selected={@condition["operator"] == "gt"}>greater than</option>
        <option value="gte" selected={@condition["operator"] == "gte"}>at least</option>
        <option value="lt" selected={@condition["operator"] == "lt"}>less than</option>
        <option value="lte" selected={@condition["operator"] == "lte"}>at most</option>
        <option value="in" selected={@condition["operator"] == "in"}>is one of</option>
        <option value="not_in" selected={@condition["operator"] == "not_in"}>is not one of</option>
        <option value="contains" selected={@condition["operator"] == "contains"}>contains</option>
        <option value="between" selected={@condition["operator"] == "between"}>between</option>
      </select>

      <%!-- Value input --%>
      <input
        type="text"
        name={"conditions[#{@index}][value]"}
        value={format_condition_value(@condition["value"])}
        class="input input-sm input-bordered flex-1 min-w-0"
        placeholder="Value..."
      />

      <%!-- Remove button --%>
      <%= if @removable do %>
        <button
          type="button"
          phx-click="remove_condition"
          phx-value-index={@index}
          class="btn btn-ghost btn-sm btn-circle"
          title="Remove condition"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a match type selector (All/Any).

  ## Attributes

    * `:selected` - The currently selected match type ("all" or "any").
    * `:name` - The form field name. Defaults to "match_type".
  """
  attr :selected, :string, default: "all"
  attr :name, :string, default: "match_type"

  def match_type_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="text-sm text-base-content/70">Match</span>
      <select name={@name} class="select select-sm select-bordered">
        <option value="all" selected={@selected == "all"}>all conditions (AND)</option>
        <option value="any" selected={@selected == "any"}>any condition (OR)</option>
      </select>
    </div>
    """
  end

  @doc """
  Renders a smart rules builder section.

  ## Attributes

    * `:rules` - The current rules map. Defaults to empty rules.
    * `:show_preview` - Whether to show a preview button. Defaults to true.
  """
  attr :rules, :map, default: %{"match_type" => "all", "conditions" => []}
  attr :show_preview, :boolean, default: true

  def smart_rules_builder(assigns) do
    conditions = Map.get(assigns.rules, "conditions", [])
    assigns = assign(assigns, :conditions, conditions)

    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <.match_type_selector selected={Map.get(@rules, "match_type", "all")} />
        <button type="button" phx-click="add_condition" class="btn btn-sm btn-ghost gap-1">
          <.icon name="hero-plus" class="w-4 h-4" /> Add Condition
        </button>
      </div>

      <div class="space-y-2">
        <%= if Enum.empty?(@conditions) do %>
          <div class="p-8 text-center text-base-content/50 bg-base-200 rounded-lg">
            <.icon name="hero-funnel" class="w-12 h-12 mx-auto mb-2 opacity-50" />
            <p>No conditions yet</p>
            <p class="text-sm">Add conditions to filter which items appear in this collection</p>
          </div>
        <% else %>
          <%= for {condition, index} <- Enum.with_index(@conditions) do %>
            <.rule_condition
              index={index}
              condition={condition}
              removable={length(@conditions) > 1}
            />
          <% end %>
        <% end %>
      </div>

      <%!-- Sort and limit options --%>
      <div class="divider">Sort & Limit</div>
      <div class="flex gap-4">
        <div class="flex-1">
          <label class="label">
            <span class="label-text text-sm">Sort by</span>
          </label>
          <div class="flex gap-2">
            <select name="sort_field" class="select select-sm select-bordered flex-1">
              <option value="">Default</option>
              <option value="title" selected={get_in(@rules, ["sort", "field"]) == "title"}>
                Title
              </option>
              <option value="year" selected={get_in(@rules, ["sort", "field"]) == "year"}>
                Year
              </option>
              <option value="rating" selected={get_in(@rules, ["sort", "field"]) == "rating"}>
                Rating
              </option>
              <option value="added_date" selected={get_in(@rules, ["sort", "field"]) == "added_date"}>
                Date Added
              </option>
            </select>
            <select name="sort_direction" class="select select-sm select-bordered w-24">
              <option value="asc" selected={get_in(@rules, ["sort", "direction"]) != "desc"}>
                Asc
              </option>
              <option value="desc" selected={get_in(@rules, ["sort", "direction"]) == "desc"}>
                Desc
              </option>
            </select>
          </div>
        </div>
        <div class="w-32">
          <label class="label">
            <span class="label-text text-sm">Limit</span>
          </label>
          <input
            type="number"
            name="limit"
            min="0"
            max="1000"
            placeholder="No limit"
            value={Map.get(@rules, "limit")}
            class="input input-sm input-bordered w-full"
          />
        </div>
      </div>

      <%= if @show_preview do %>
        <div class="flex justify-end">
          <button type="button" phx-click="preview_rules" class="btn btn-sm btn-ghost gap-1">
            <.icon name="hero-eye" class="w-4 h-4" /> Preview Results
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders filter controls for collections view.

  ## Attributes

    * `:search_query` - Current search query. Defaults to empty string.
    * `:filter_type` - Current type filter ("manual", "smart", or nil for all).
    * `:filter_visibility` - Current visibility filter ("private", "shared", or nil).
  """
  attr :search_query, :string, default: ""
  attr :filter_type, :string, default: nil
  attr :filter_visibility, :string, default: nil

  def collection_filters(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row gap-3 md:gap-4 mb-4 md:mb-6">
      <%!-- Search input --%>
      <div class="flex-1">
        <.form for={%{}} phx-change="search" id="collection-search-form" class="w-full">
          <input
            type="text"
            name="search"
            value={@search_query}
            placeholder="Search collections..."
            phx-debounce="300"
            class="input input-bordered w-full"
          />
        </.form>
      </div>

      <%!-- Filters --%>
      <.form for={%{}} phx-change="filter" id="collection-filter-form" class="join">
        <select name="type" class="select select-bordered join-item">
          <option value="" selected={is_nil(@filter_type)}>All Types</option>
          <option value="manual" selected={@filter_type == "manual"}>Manual</option>
          <option value="smart" selected={@filter_type == "smart"}>Smart</option>
        </select>

        <select name="visibility" class="select select-bordered join-item">
          <option value="" selected={is_nil(@filter_visibility)}>All Visibility</option>
          <option value="private" selected={@filter_visibility == "private"}>Private</option>
          <option value="shared" selected={@filter_visibility == "shared"}>Shared</option>
        </select>
      </.form>
    </div>
    """
  end

  @doc """
  Renders an empty state for collections.

  ## Attributes

    * `:message` - The message to display.
  """
  attr :message, :string, default: "No collections found"

  slot :actions

  def collection_empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16">
      <.icon name="hero-folder" class="w-16 h-16 mb-4 text-base-content/30" />
      <h3 class="text-xl font-semibold text-base-content/70 mb-2">{@message}</h3>
      <p class="text-base-content/50 text-center max-w-md">
        Create a collection to organize your media into custom groups.
      </p>
      <%= if @actions != [] do %>
        <div class="mt-4">
          {render_slot(@actions)}
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp type_badge_class("smart"), do: "badge-secondary"
  defp type_badge_class("manual"), do: "badge-primary"
  defp type_badge_class(_), do: "badge-ghost"

  defp type_icon("smart"), do: "hero-sparkles"
  defp type_icon("manual"), do: "hero-folder"
  defp type_icon(_), do: "hero-folder"

  defp type_label("smart"), do: "Smart"
  defp type_label("manual"), do: "Manual"
  defp type_label(_), do: "Manual"

  defp format_condition_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_condition_value(value), do: value

  @doc """
  Returns the list of valid fields for smart rules.
  Useful for building dynamic field selectors.
  """
  def valid_fields, do: SmartRules.valid_fields()

  @doc """
  Returns the list of valid operators for smart rules.
  """
  def valid_operators, do: SmartRules.valid_operators()
end
