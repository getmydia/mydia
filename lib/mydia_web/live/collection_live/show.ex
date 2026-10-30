defmodule MydiaWeb.CollectionLive.Show do
  @moduledoc """
  LiveView for viewing and managing a single collection.

  Supports:
  - Viewing collection items (manual) or matching items (smart)
  - Editing collection settings with UI-based smart rules editor
  - Managing smart rules for smart collections
  - Adding/removing items from manual collections
  - Reordering items in manual collections
  """
  use MydiaWeb, :live_view

  alias Mydia.Collections
  alias Mydia.Collections.Collection
  alias Mydia.Media
  alias MydiaWeb.CollectionLive.{RuleLabels, SmartRulesParams}

  import MydiaWeb.CollectionLive.Components,
    only: [smart_rules_editor: 1, load_value_options: 1, value_string: 1]

  @items_per_page 50
  @default_condition %{"field" => "", "operator" => "eq", "value" => ""}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Collections.get_collection(user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Collection not found"))
         |> push_navigate(to: ~p"/collections")}

      collection ->
        {:ok,
         socket
         |> assign(:collection, collection)
         |> assign(:page_title, collection.name)
         |> assign(:page, 0)
         |> assign(:has_more, true)
         |> assign(:show_edit_modal, false)
         |> assign(:show_delete_modal, false)
         |> assign(:show_add_items_modal, false)
         |> assign(:add_items_search, "")
         |> assign(:add_items_results, [])
         |> assign(:collection_item_ids, MapSet.new())
         |> assign(:edit_form, to_form(%{}, as: :collection))
         |> assign_default_rules()
         |> stream(:items, [])
         |> load_items(reset: true)}
    end
  end

  defp assign_default_rules(socket) do
    socket
    |> assign(:rules_conditions, [@default_condition])
    |> assign(:rules_match_type, "all")
    |> assign(:rules_sort_field, "")
    |> assign(:rules_sort_direction, "desc")
    |> assign(:rules_limit, nil)
  end

  defp parse_existing_rules(socket, collection) do
    case collection.smart_rules do
      nil ->
        assign_default_rules(socket)

      rules_json when is_binary(rules_json) ->
        case Jason.decode(rules_json) do
          {:ok, rules} ->
            conditions =
              case Map.get(rules, "conditions", []) do
                [] -> [@default_condition]
                conds -> Enum.map(conds, &normalize_condition/1)
              end

            sort_field = get_in(rules, ["sort", "field"]) || ""
            sort_direction = get_in(rules, ["sort", "direction"]) || "desc"
            limit = Map.get(rules, "limit")

            socket
            |> assign(:rules_conditions, conditions)
            |> assign(:rules_match_type, Map.get(rules, "match_type", "all"))
            |> assign(:rules_sort_field, sort_field)
            |> assign(:rules_sort_direction, sort_direction)
            |> assign(:rules_limit, limit)

          {:error, _} ->
            assign_default_rules(socket)
        end
    end
  end

  defp normalize_condition(cond) do
    %{
      "field" => Map.get(cond, "field", ""),
      "operator" => Map.get(cond, "operator", "eq"),
      "value" => value_string(Map.get(cond, "value", ""))
    }
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Auto-open edit modal if ?edit=true query param is present
    socket =
      if params["edit"] == "true" do
        collection = socket.assigns.collection
        user = socket.assigns.current_user

        if can_edit?(collection, user) and not collection.is_system do
          socket =
            socket
            |> assign(:show_edit_modal, true)
            |> parse_existing_rules(collection)

          if collection.type == "smart",
            do: load_value_options(socket),
            else: socket
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="container mx-auto px-4 py-6">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
          <div class="flex items-center gap-4">
            <.link navigate={~p"/collections"} class="btn btn-ghost btn-sm btn-circle shrink-0">
              <.icon name="hero-arrow-left" class="w-5 h-5" />
            </.link>
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <h1 class="text-2xl font-bold min-w-0 break-words max-sm:wrap-anywhere">
                  {@collection.name}
                </h1>
                <%= if @collection.is_system do %>
                  <span class="badge badge-ghost gap-1">
                    <.icon name="hero-star" class="w-3 h-3" /> {gettext("System")}
                  </span>
                <% end %>
                <span class={["badge badge-sm gap-1", type_badge_class(@collection.type)]}>
                  <.icon name={type_icon(@collection.type)} class="w-3 h-3" />
                  {type_label(@collection.type)}
                </span>
              </div>
              <%= if @collection.description do %>
                <p class="text-base-content/60">{@collection.description}</p>
              <% end %>
            </div>
          </div>
          <div class="flex items-center gap-2 max-sm:flex-wrap">
            <span class="text-base-content/60">
              {ngettext("%{count} item", "%{count} items", @item_count)}
            </span>
            <%!-- Play All button --%>
            <%= if @item_count > 0 do %>
              <button
                type="button"
                class="btn btn-secondary btn-sm gap-1"
                phx-click="play_all"
              >
                <.icon name="hero-play" class="w-4 h-4" /> {gettext("Play All")}
              </button>
            <% end %>
            <%!-- Manual collection: Add Items button --%>
            <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
              <button
                type="button"
                class="btn btn-primary btn-sm gap-1"
                phx-click="open_add_items_modal"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add Items")}
              </button>
            <% end %>
            <%!-- Smart collection: Edit Rules button --%>
            <%= if @collection.type == "smart" do %>
              <button
                type="button"
                class="btn btn-ghost btn-sm gap-1"
                phx-click="open_edit_modal"
              >
                <.icon name="hero-funnel" class="w-4 h-4" /> {gettext("Edit Rules")}
              </button>
            <% end %>
            <%!-- Pin/unpin as a sidebar section: owned, smart, non-system collections only --%>
            <%= if can_pin?(@collection, @current_user) do %>
              <%= if @collection.pinned_position do %>
                <button
                  id="unpin-collection"
                  type="button"
                  class="btn btn-ghost btn-sm gap-1"
                  phx-click="unpin_collection"
                >
                  <.icon name="hero-bookmark-slash" class="w-4 h-4" /> {gettext("Unpin from sidebar")}
                </button>
              <% else %>
                <button
                  id="pin-collection"
                  type="button"
                  class="btn btn-outline btn-primary btn-sm gap-1"
                  phx-click="pin_collection"
                >
                  <.icon name="hero-bookmark" class="w-4 h-4" /> {gettext("Pin to sidebar")}
                </button>
              <% end %>
            <% end %>
            <%!-- Settings dropdown for non-system collections --%>
            <%= if not @collection.is_system and can_edit?(@collection, @current_user) do %>
              <div class="dropdown dropdown-end shrink-0">
                <label tabindex="0" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
                >
                  <li>
                    <button type="button" phx-click="open_edit_modal">
                      <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit Collection")}
                    </button>
                  </li>
                  <li>
                    <button type="button" phx-click="open_delete_modal" class="text-error">
                      <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete Collection")}
                    </button>
                  </li>
                </ul>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Items Grid with infinite scroll --%>
        <div
          id="collection-items"
          phx-update="stream"
          phx-viewport-bottom={@has_more && "load_more"}
          class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3 md:gap-4"
        >
          <div :for={{id, item} <- @streams.items} id={id} class="relative group h-full">
            <%!-- Remove button for manual collections --%>
            <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
              <button
                type="button"
                phx-click="remove_item"
                phx-value-id={item.id}
                class="absolute top-2 right-2 z-10 btn btn-circle btn-xs btn-error opacity-0 group-hover:opacity-100 transition-opacity"
                title={gettext("Remove from collection")}
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            <% end %>

            <.link navigate={item_href(item)} class="block h-full">
              <div class="card h-full bg-base-100 shadow-lg hover:shadow-xl transition-shadow duration-200">
                <.poster_figure src={item.poster_url} alt={item.title} class="rounded-t-box" />
                <.poster_card_body title={item.title}>
                  <:meta>
                    <span class="text-xs text-base-content/70">{item.year}</span>
                  </:meta>
                </.poster_card_body>
              </div>
            </.link>
          </div>
        </div>

        <%!-- Loading indicator --%>
        <div :if={@has_more and @item_count > 0} class="flex justify-center py-8">
          <span class="loading loading-spinner loading-md text-primary"></span>
        </div>

        <%!-- Empty state --%>
        <div
          :if={@item_count == 0}
          class="flex flex-col items-center justify-center py-16"
        >
          <.icon name="hero-film" class="w-16 h-16 mb-4 text-base-content/30" />
          <h3 class="text-xl font-semibold text-base-content/70 mb-2">
            {gettext("No items yet")}
          </h3>
          <p class="text-base-content/50 text-center max-w-md mb-4">
            <%= if @collection.type == "smart" do %>
              {gettext("No items match your smart rules. Try adjusting the conditions.")}
            <% else %>
              {gettext("Start building your collection by adding movies and TV shows.")}
            <% end %>
          </p>
          <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
            <button
              type="button"
              class="btn btn-primary gap-2"
              phx-click="open_add_items_modal"
            >
              <.icon name="hero-plus" class="w-5 h-5" /> {gettext("Add Items")}
            </button>
          <% end %>
          <%= if @collection.type == "smart" do %>
            <button
              type="button"
              class="btn btn-secondary gap-2"
              phx-click="open_edit_modal"
            >
              <.icon name="hero-funnel" class="w-5 h-5" /> {gettext("Edit Rules")}
            </button>
          <% end %>
        </div>

        <%!-- Edit Collection Modal --%>
        <.modal
          :if={@show_edit_modal}
          id="edit-collection-modal"
          show={@show_edit_modal}
          on_cancel={JS.push("close_edit_modal")}
        >
          <:title>
            <div class="flex items-center gap-3">
              <div class={[
                "flex items-center justify-center w-10 h-10 rounded-xl",
                @collection.type == "smart" && "bg-secondary/20",
                @collection.type != "smart" && "bg-primary/20"
              ]}>
                <.icon
                  name={
                    if @collection.type == "smart", do: "hero-sparkles", else: "hero-pencil-square"
                  }
                  class={
                    if @collection.type == "smart",
                      do: "w-5 h-5 text-secondary",
                      else: "w-5 h-5 text-primary"
                  }
                />
              </div>
              <div>
                <div class="font-bold text-lg">{gettext("Edit Collection")}</div>
                <div class="text-xs text-base-content/60 font-normal flex items-center gap-1">
                  <span class={[
                    "badge badge-xs",
                    @collection.type == "smart" && "badge-secondary",
                    @collection.type != "smart" && "badge-primary"
                  ]}>
                    {type_label(@collection.type)}
                  </span>
                  {@collection.name}
                </div>
              </div>
            </div>
          </:title>

          <.form
            for={@edit_form}
            phx-submit="update_collection"
            phx-change="update_rules"
            id="edit-collection-form"
          >
            <div class="space-y-3">
              <%!-- Name & Visibility Row --%>
              <div class={["grid gap-3", @current_user.role == "admin" && "grid-cols-2"]}>
                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-sm font-medium">{gettext("Name")}</span>
                  </label>
                  <input
                    type="text"
                    name="collection[name]"
                    value={@collection.name}
                    class="input input-sm input-bordered w-full"
                    required
                  />
                </div>

                <%= if @current_user.role == "admin" do %>
                  <div class="form-control">
                    <label class="label py-1">
                      <span class="label-text text-sm font-medium">{gettext("Visibility")}</span>
                    </label>
                    <select
                      name="collection[visibility]"
                      class="select select-sm select-bordered w-full"
                    >
                      <option value="private" selected={@collection.visibility == "private"}>
                        {gettext("Private")}
                      </option>
                      <option value="shared" selected={@collection.visibility == "shared"}>
                        {gettext("Shared")}
                      </option>
                    </select>
                  </div>
                <% end %>
              </div>

              <%!-- Description --%>
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-sm font-medium">{gettext("Description")}</span>
                  <span class="label-text-alt text-xs">{gettext("Optional")}</span>
                </label>
                <input
                  type="text"
                  name="collection[description]"
                  value={@collection.description}
                  class="input input-sm input-bordered w-full"
                  placeholder={gettext("What's this collection about?")}
                />
              </div>

              <%!-- Smart Rules for smart collections --%>
              <%= if @collection.type == "smart" do %>
                <div class="divider my-2 text-xs text-base-content/50">
                  <.icon name="hero-sparkles" class="w-4 h-4" /> {gettext("Smart Rules")}
                </div>
                <.smart_rules_editor
                  conditions={@rules_conditions}
                  match_type={@rules_match_type}
                  sort_field={@rules_sort_field}
                  sort_direction={@rules_sort_direction}
                  limit={@rules_limit}
                  value_options={@rules_value_options}
                />
              <% end %>
            </div>
          </.form>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_edit_modal">
              {gettext("Cancel")}
            </button>
            <button type="submit" form="edit-collection-form" class="btn btn-primary">
              {gettext("Save Changes")}
            </button>
          </:actions>
        </.modal>

        <%!-- Delete Confirmation Modal --%>
        <.modal
          :if={@show_delete_modal}
          id="delete-collection-modal"
          show={@show_delete_modal}
          on_cancel={JS.push("close_delete_modal")}
        >
          <:title>{gettext("Delete Collection?")}</:title>

          <p class="text-base-content/70">
            {gettext("Are you sure you want to delete %{name}? This action cannot be undone.",
              name: @collection.name
            )}
          </p>
          <p class="text-sm text-base-content/50 mt-2">
            {gettext("The media items in this collection will not be deleted.")}
          </p>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_delete_modal">
              {gettext("Cancel")}
            </button>
            <button type="button" class="btn btn-error" phx-click="delete_collection">
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete Collection")}
            </button>
          </:actions>
        </.modal>

        <%!-- Add Items Modal (Manual collections only) --%>
        <.modal
          :if={@show_add_items_modal}
          id="add-items-modal"
          show={@show_add_items_modal}
          on_cancel={JS.push("close_add_items_modal")}
        >
          <:title>{gettext("Add Items to Collection")}</:title>

          <%!-- Search input with icon --%>
          <.form
            for={%{}}
            phx-change="search_add_items"
            id="add-items-search-form"
            class="w-full mb-6"
          >
            <label class="input input-lg input-bordered w-full flex items-center gap-3 bg-base-200/50 focus-within:outline-none focus-within:ring-2 focus-within:ring-primary">
              <.icon name="hero-magnifying-glass" class="w-5 h-5 text-base-content/50 flex-shrink-0" />
              <input
                type="text"
                name="search"
                value={@add_items_search}
                placeholder={gettext("Search movies or TV shows...")}
                phx-debounce="300"
                class="grow bg-transparent border-none focus:outline-none text-lg min-w-0"
                autofocus
              />
              <%= if @add_items_search != "" do %>
                <button
                  type="button"
                  phx-click="search_add_items"
                  phx-value-search=""
                  class="btn btn-ghost btn-sm btn-circle flex-shrink-0"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              <% end %>
            </label>
          </.form>

          <%!-- Search results --%>
          <div class="min-h-[280px] max-h-[400px] overflow-y-auto -mx-2">
            <%= cond do %>
              <% String.length(@add_items_search) < 2 -> %>
                <%!-- Initial state --%>
                <div class="flex flex-col items-center justify-center py-16 text-base-content/50">
                  <.icon name="hero-magnifying-glass" class="w-16 h-16 mb-4 opacity-30" />
                  <p class="font-medium">{gettext("Search your library")}</p>
                  <p class="text-sm">{gettext("Type at least 2 characters to search")}</p>
                </div>
              <% @add_items_results == [] -> %>
                <%!-- No results --%>
                <div class="flex flex-col items-center justify-center py-16 text-base-content/50">
                  <.icon name="hero-face-frown" class="w-16 h-16 mb-4 opacity-30" />
                  <p class="font-medium">{gettext("No results found")}</p>
                  <p class="text-sm">{gettext("Try a different search term")}</p>
                </div>
              <% true -> %>
                <%!-- Results list --%>
                <div class="divide-y divide-base-200">
                  <%= for item <- @add_items_results do %>
                    <% in_collection? = MapSet.member?(@collection_item_ids, item.id) %>
                    <button
                      type="button"
                      phx-click="toggle_item_in_collection"
                      phx-value-id={item.id}
                      class={[
                        "w-full flex items-center gap-3 p-2 text-left transition-colors",
                        "hover:bg-base-200 focus:outline-none focus:bg-base-200",
                        in_collection? && "bg-success/10"
                      ]}
                    >
                      <%!-- Poster thumbnail --%>
                      <div class="w-12 h-18 flex-shrink-0 rounded overflow-hidden bg-base-300">
                        <img
                          :if={item.poster_url}
                          src={item.poster_url}
                          alt=""
                          class="w-full h-full object-cover"
                          loading="lazy"
                        />
                        <div
                          :if={!item.poster_url}
                          class="w-full h-full flex items-center justify-center"
                        >
                          <.icon name="hero-film" class="w-6 h-6 text-base-content/20" />
                        </div>
                      </div>

                      <%!-- Title and metadata --%>
                      <div class="flex-1 min-w-0">
                        <h4 class="font-medium truncate">{item.title}</h4>
                        <div class="flex items-center gap-2 text-sm text-base-content/60">
                          <span>{item.year}</span>
                          <span class="badge badge-xs">
                            {if item.type == "movie", do: gettext("Movie"), else: gettext("TV Show")}
                          </span>
                        </div>
                      </div>

                      <%!-- Action indicator --%>
                      <div class="flex-shrink-0">
                        <%= if in_collection? do %>
                          <div class="btn btn-sm btn-success btn-outline gap-1">
                            <.icon name="hero-check" class="w-4 h-4" />
                            <span class="hidden sm:inline">{gettext("Added")}</span>
                          </div>
                        <% else %>
                          <div class="btn btn-sm btn-ghost gap-1">
                            <.icon name="hero-plus" class="w-4 h-4" />
                            <span class="hidden sm:inline">{gettext("Add")}</span>
                          </div>
                        <% end %>
                      </div>
                    </button>
                  <% end %>
                </div>
            <% end %>
          </div>

          <:actions>
            <button type="button" class="btn" phx-click="close_add_items_modal">
              {gettext("Done")}
            </button>
          </:actions>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  alias MydiaWeb.MediaLive.Show.Helpers, as: PlayerHelpers

  @impl true
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_items(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("play_all", _params, socket) do
    collection = socket.assigns.collection

    # Get all playable items from the collection
    playable_items = Collections.get_playable_items(socket.assigns.current_scope, collection)

    case playable_items do
      [] ->
        {:noreply, put_flash(socket, :error, gettext("No playable items in this collection"))}

      items ->
        # Build the queue player URL
        queue_url = PlayerHelpers.flutter_queue_player_url(items)
        {:noreply, redirect(socket, external: queue_url)}
    end
  end

  def handle_event("remove_item", %{"id" => item_id}, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    if can_edit?(collection, user) do
      case Collections.remove_item(collection, item_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> stream_delete(:items, %{id: item_id})
           |> update(:item_count, &(&1 - 1))
           |> put_flash(:info, gettext("Item removed from collection"))}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("Item not found in collection"))}

        {:error, :smart_collection} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot remove items from smart collections"))}
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to edit this collection"))}
    end
  end

  def handle_event("open_edit_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_edit_modal, true)
      |> parse_existing_rules(socket.assigns.collection)

    socket =
      if socket.assigns.collection.type == "smart",
        do: load_value_options(socket),
        else: socket

    {:noreply, socket}
  end

  def handle_event("close_edit_modal", _params, socket) do
    {:noreply, assign(socket, :show_edit_modal, false)}
  end

  def handle_event("add_condition", _params, socket) do
    conditions = socket.assigns.rules_conditions ++ [@default_condition]
    {:noreply, assign(socket, :rules_conditions, conditions)}
  end

  def handle_event("remove_condition", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    conditions = List.delete_at(socket.assigns.rules_conditions, index)

    # Ensure at least one condition remains
    conditions = if conditions == [], do: [@default_condition], else: conditions

    {:noreply, assign(socket, :rules_conditions, conditions)}
  end

  def handle_event("update_rules", params, socket) do
    # Only process if we're editing a smart collection
    if socket.assigns.collection.type != "smart" do
      {:noreply, socket}
    else
      # Update rules from form params
      socket =
        socket
        |> update_conditions_from_params(params)
        |> update_match_type_from_params(params)
        |> update_sort_from_params(params)
        |> update_limit_from_params(params)

      {:noreply, socket}
    end
  end

  def handle_event("open_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  def handle_event("update_collection", %{"collection" => params} = full_params, socket) do
    alias Mydia.Collections.SmartRules

    collection = socket.assigns.collection
    user = socket.assigns.current_user

    # Build smart_rules JSON for smart collections
    {smart_rules, validation_result} =
      if collection.type == "smart" do
        json = SmartRulesParams.build_json(full_params)
        {json, SmartRules.validate(json)}
      else
        {nil, {:ok, nil}}
      end

    # Validate smart rules before saving
    case validation_result do
      {:error, errors} ->
        error_msg = RuleLabels.invalid_rules_message(errors)
        {:noreply, put_flash(socket, :error, error_msg)}

      {:ok, _} ->
        attrs = %{
          name: params["name"],
          description: params["description"],
          visibility: params["visibility"],
          smart_rules: smart_rules
        }

        case Collections.update_collection(user, collection, attrs) do
          {:ok, updated_collection} ->
            {:noreply,
             socket
             |> assign(:collection, updated_collection)
             |> assign(:page_title, updated_collection.name)
             |> assign(:show_edit_modal, false)
             |> put_flash(:info, gettext("Collection updated"))
             |> load_items(reset: true)}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("You don't have permission to edit this collection")
             )}

          {:error, :system_collection} ->
            {:noreply, put_flash(socket, :error, gettext("System collections cannot be edited"))}

          {:error, %Ecto.Changeset{} = changeset} ->
            error_msg = extract_changeset_error(changeset)
            {:noreply, put_flash(socket, :error, error_msg)}
        end
    end
  end

  def handle_event("delete_collection", _params, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    case Collections.delete_collection(user, collection) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Collection deleted"))
         |> push_navigate(to: ~p"/collections")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, gettext("You don't have permission to delete this collection"))}

      {:error, :system_collection} ->
        {:noreply, put_flash(socket, :error, gettext("System collections cannot be deleted"))}
    end
  end

  def handle_event("pin_collection", _params, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    case Collections.pin_section(user, collection) do
      {:ok, pinned} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Pinned to sidebar"))
         |> push_navigate(to: ~p"/sections/#{pinned.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, pin_error_message(reason))}
    end
  end

  def handle_event("unpin_collection", _params, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user

    case Collections.unpin_section(user, collection) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:collection, updated)
         |> put_flash(:info, gettext("Removed from sidebar"))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, pin_error_message(reason))}
    end
  end

  # Add Items Modal handlers

  def handle_event("open_add_items_modal", _params, socket) do
    collection = socket.assigns.collection

    # Load current collection item IDs
    item_ids =
      socket.assigns.current_scope
      |> Collections.list_collection_items(collection)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {:noreply,
     socket
     |> assign(:show_add_items_modal, true)
     |> assign(:collection_item_ids, item_ids)
     |> assign(:add_items_search, "")
     |> assign(:add_items_results, [])}
  end

  def handle_event("close_add_items_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_items_modal, false)
     |> assign(:add_items_search, "")
     |> assign(:add_items_results, [])}
  end

  def handle_event("search_add_items", %{"search" => query}, socket) do
    results =
      if String.length(query) >= 2 do
        Media.list_media_items(socket.assigns.current_scope,
          search: query,
          limit: 20,
          order_by: :title
        )
        |> Enum.map(&format_search_result/1)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:add_items_search, query)
     |> assign(:add_items_results, results)}
  end

  def handle_event("toggle_item_in_collection", %{"id" => item_id}, socket) do
    collection = socket.assigns.collection
    user = socket.assigns.current_user
    item_ids = socket.assigns.collection_item_ids

    if can_edit?(collection, user) do
      if MapSet.member?(item_ids, item_id) do
        # Remove item
        case Collections.remove_item(collection, item_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> stream_delete(:items, %{id: item_id})
             |> update(:item_count, &(&1 - 1))
             |> assign(:collection_item_ids, MapSet.delete(item_ids, item_id))
             |> put_flash(:info, gettext("Item removed from collection"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to remove item"))}
        end
      else
        # Add item
        case Collections.add_item(collection, item_id) do
          {:ok, _} ->
            # Fetch the media item to add to stream
            media_item = Media.get_media_item!(socket.assigns.current_scope, item_id)

            stream_item = %{
              id: media_item.id,
              title: media_item.title,
              year: media_item.year,
              type: media_item.type,
              poster_url: build_poster_url(media_item)
            }

            {:noreply,
             socket
             |> stream_insert(:items, stream_item, at: -1)
             |> update(:item_count, &(&1 + 1))
             |> assign(:collection_item_ids, MapSet.put(item_ids, item_id))
             |> put_flash(:info, gettext("Item added to collection"))}

          {:error, :smart_collection} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot add items to smart collections"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to add item"))}
        end
      end
    else
      {:noreply,
       put_flash(socket, :error, gettext("You don't have permission to edit this collection"))}
    end
  end

  defp update_conditions_from_params(socket, params) do
    case params["conditions"] do
      nil ->
        socket

      cond_params when is_map(cond_params) ->
        # Get the old conditions to preserve values when field changes
        old_conditions = socket.assigns.rules_conditions

        new_conditions =
          cond_params
          |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
          |> Enum.with_index()
          |> Enum.map(fn {{_, cond}, index} ->
            old_cond = Enum.at(old_conditions, index) || @default_condition
            old_field = old_cond["field"]
            new_field = cond["field"] || ""

            # If field changed, reset value and set default operator for new field
            if old_field != new_field and new_field != "" do
              default_operators = Mydia.Collections.SmartRulesFields.get_operators(new_field)

              default_op =
                if Enum.empty?(default_operators),
                  do: "eq",
                  else: to_string(hd(default_operators))

              %{
                "field" => new_field,
                "operator" => default_op,
                "value" => ""
              }
            else
              %{
                "field" => new_field,
                "operator" => cond["operator"] || old_cond["operator"] || "eq",
                "value" => value_string(cond["value"])
              }
            end
          end)

        assign(socket, :rules_conditions, new_conditions)
    end
  end

  defp update_match_type_from_params(socket, params) do
    case params["match_type"] do
      nil -> socket
      match_type -> assign(socket, :rules_match_type, match_type)
    end
  end

  defp update_sort_from_params(socket, params) do
    socket
    |> maybe_assign(:rules_sort_field, params["sort_field"])
    |> maybe_assign(:rules_sort_direction, params["sort_direction"])
  end

  defp update_limit_from_params(socket, params) do
    case params["limit"] do
      nil -> socket
      "" -> assign(socket, :rules_limit, nil)
      val -> assign(socket, :rules_limit, String.to_integer(val))
    end
  rescue
    ArgumentError -> socket
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  defp extract_changeset_error(changeset) do
    case changeset.errors do
      [{_field, {_msg, _opts} = error} | _] -> translate_error(error)
      _ -> gettext("Failed to update collection")
    end
  end

  defp format_search_result(item) do
    %{
      id: item.id,
      title: item.title,
      year: item.year,
      type: item.type,
      poster_url: build_poster_url(item)
    }
  end

  # Private helpers

  defp load_items(socket, opts) do
    reset = Keyword.get(opts, :reset, false)
    collection = socket.assigns.collection
    page = if reset, do: 0, else: socket.assigns.page
    offset = page * @items_per_page

    items =
      Collections.list_collection_items(socket.assigns.current_scope, collection,
        limit: @items_per_page,
        offset: offset
      )

    item_count = Collections.item_count(socket.assigns.current_scope, collection)

    items_with_metadata =
      Enum.map(items, fn item ->
        %{
          id: item.id,
          title: item.title,
          year: item.year,
          type: item.type,
          poster_url: build_poster_url(item)
        }
      end)

    has_more = length(items) == @items_per_page

    socket
    |> assign(:item_count, item_count)
    |> assign(:has_more, has_more)
    |> assign(:page, page)
    |> stream(:items, items_with_metadata, reset: reset)
  end

  defp build_poster_url(%{metadata: %{"poster_path" => path}}) when is_binary(path) do
    ImageUrl.poster_url(path, "w342")
  end

  defp build_poster_url(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "poster_path") || Map.get(metadata, :poster_path) do
      nil -> nil
      path -> ImageUrl.poster_url(path, "w342")
    end
  end

  defp build_poster_url(_), do: nil

  defp item_href(%{type: "movie", id: id}), do: ~p"/movies/#{id}"
  defp item_href(%{type: "tv_show", id: id}), do: ~p"/tv/#{id}"
  defp item_href(%{id: id}), do: ~p"/media/#{id}"

  defp can_edit?(%Collection{user_id: user_id}, %{id: current_user_id}) do
    user_id == current_user_id
  end

  # A collection can be pinned to the sidebar only when it is owned, smart
  # (a manual collection has no rules to scope a section query), and not a
  # system collection (Favorites cannot be repurposed as a section).
  defp can_pin?(%Collection{type: "smart", is_system: false} = collection, user) do
    can_edit?(collection, user)
  end

  defp can_pin?(_collection, _user), do: false

  defp pin_error_message(:not_smart),
    do: gettext("Only smart collections can be pinned to the sidebar")

  defp pin_error_message(:unauthorized),
    do: gettext("You don't have permission to pin this collection")

  defp pin_error_message(:system_collection),
    do: gettext("System collections cannot be pinned to the sidebar")

  defp pin_error_message(%Ecto.Changeset{} = changeset), do: extract_changeset_error(changeset)

  defp type_badge_class("smart"), do: "badge-secondary"
  defp type_badge_class("manual"), do: "badge-primary"
  defp type_badge_class(_), do: "badge-ghost"

  defp type_icon("smart"), do: "hero-sparkles"
  defp type_icon("manual"), do: "hero-folder"
  defp type_icon(_), do: "hero-folder"

  defp type_label("smart"), do: gettext("Smart")
  defp type_label("manual"), do: gettext("Manual")
  defp type_label(_), do: gettext("Manual")
end
