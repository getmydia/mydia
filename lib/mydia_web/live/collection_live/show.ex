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

  @items_per_page 50
  @default_condition %{"field" => "", "operator" => "eq", "value" => ""}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Collections.get_collection(user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Collection not found")
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
      "value" => format_condition_value(Map.get(cond, "value", ""))
    }
  end

  defp format_condition_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_condition_value(value), do: to_string(value)

  @impl true
  def handle_params(params, _url, socket) do
    # Auto-open edit modal if ?edit=true query param is present
    socket =
      if params["edit"] == "true" do
        collection = socket.assigns.collection
        user = socket.assigns.current_user

        if can_edit?(collection, user) and not collection.is_system do
          socket
          |> assign(:show_edit_modal, true)
          |> parse_existing_rules(collection)
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
            <.link navigate={~p"/collections"} class="btn btn-ghost btn-sm btn-circle">
              <.icon name="hero-arrow-left" class="w-5 h-5" />
            </.link>
            <div>
              <div class="flex items-center gap-2">
                <h1 class="text-2xl font-bold">{@collection.name}</h1>
                <%= if @collection.is_system do %>
                  <span class="badge badge-ghost gap-1">
                    <.icon name="hero-star" class="w-3 h-3" /> System
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
          <div class="flex items-center gap-2">
            <span class="text-base-content/60">
              {@item_count} {if @item_count == 1, do: "item", else: "items"}
            </span>
            <%!-- Play All button --%>
            <%= if @item_count > 0 do %>
              <button
                type="button"
                class="btn btn-secondary btn-sm gap-1"
                phx-click="play_all"
              >
                <.icon name="hero-play" class="w-4 h-4" /> Play All
              </button>
            <% end %>
            <%!-- Manual collection: Add Items button --%>
            <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
              <button
                type="button"
                class="btn btn-primary btn-sm gap-1"
                phx-click="open_add_items_modal"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add Items
              </button>
            <% end %>
            <%!-- Smart collection: Edit Rules button --%>
            <%= if @collection.type == "smart" do %>
              <button
                type="button"
                class="btn btn-ghost btn-sm gap-1"
                phx-click="open_edit_modal"
              >
                <.icon name="hero-funnel" class="w-4 h-4" /> Edit Rules
              </button>
            <% end %>
            <%!-- Settings dropdown for non-system collections --%>
            <%= if not @collection.is_system and can_edit?(@collection, @current_user) do %>
              <div class="dropdown dropdown-end">
                <label tabindex="0" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-ellipsis-vertical" class="w-5 h-5" />
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
                >
                  <li>
                    <button type="button" phx-click="open_edit_modal">
                      <.icon name="hero-pencil" class="w-4 h-4" /> Edit Collection
                    </button>
                  </li>
                  <li>
                    <button type="button" phx-click="open_delete_modal" class="text-error">
                      <.icon name="hero-trash" class="w-4 h-4" /> Delete Collection
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
          <div :for={{id, item} <- @streams.items} id={id} class="relative group">
            <%!-- Remove button for manual collections --%>
            <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
              <button
                type="button"
                phx-click="remove_item"
                phx-value-id={item.id}
                class="absolute top-2 right-2 z-10 btn btn-circle btn-xs btn-error opacity-0 group-hover:opacity-100 transition-opacity"
                title="Remove from collection"
              >
                <.icon name="hero-x-mark" class="w-3 h-3" />
              </button>
            <% end %>

            <.link navigate={item_href(item)} class="block">
              <div class="card bg-base-100 shadow-lg hover:shadow-xl transition-shadow duration-200 overflow-hidden">
                <.poster_figure src={item.poster_url} alt={item.title} />
                <div class="card-body p-3">
                  <h3 class="card-title text-sm line-clamp-2">{item.title}</h3>
                  <span class="text-xs text-base-content/70">{item.year}</span>
                </div>
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
          <h3 class="text-xl font-semibold text-base-content/70 mb-2">No items yet</h3>
          <p class="text-base-content/50 text-center max-w-md mb-4">
            <%= if @collection.type == "smart" do %>
              No items match your smart rules. Try adjusting the conditions.
            <% else %>
              Start building your collection by adding movies and TV shows.
            <% end %>
          </p>
          <%= if @collection.type == "manual" and can_edit?(@collection, @current_user) do %>
            <button
              type="button"
              class="btn btn-primary gap-2"
              phx-click="open_add_items_modal"
            >
              <.icon name="hero-plus" class="w-5 h-5" /> Add Items
            </button>
          <% end %>
          <%= if @collection.type == "smart" do %>
            <button
              type="button"
              class="btn btn-secondary gap-2"
              phx-click="open_edit_modal"
            >
              <.icon name="hero-funnel" class="w-5 h-5" /> Edit Rules
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
                <div class="font-bold text-lg">Edit Collection</div>
                <div class="text-xs text-base-content/60 font-normal flex items-center gap-1">
                  <span class={[
                    "badge badge-xs",
                    @collection.type == "smart" && "badge-secondary",
                    @collection.type != "smart" && "badge-primary"
                  ]}>
                    {if @collection.type == "smart", do: "Smart", else: "Manual"}
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
                    <span class="label-text text-sm font-medium">Name</span>
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
                      <span class="label-text text-sm font-medium">Visibility</span>
                    </label>
                    <select
                      name="collection[visibility]"
                      class="select select-sm select-bordered w-full"
                    >
                      <option value="private" selected={@collection.visibility == "private"}>
                        Private
                      </option>
                      <option value="shared" selected={@collection.visibility == "shared"}>
                        Shared
                      </option>
                    </select>
                  </div>
                <% end %>
              </div>

              <%!-- Description --%>
              <div class="form-control">
                <label class="label py-1">
                  <span class="label-text text-sm font-medium">Description</span>
                  <span class="label-text-alt text-xs">Optional</span>
                </label>
                <input
                  type="text"
                  name="collection[description]"
                  value={@collection.description}
                  class="input input-sm input-bordered w-full"
                  placeholder="What's this collection about?"
                />
              </div>

              <%!-- Smart Rules for smart collections --%>
              <%= if @collection.type == "smart" do %>
                <div class="divider my-2 text-xs text-base-content/50">
                  <.icon name="hero-sparkles" class="w-4 h-4" /> Smart Rules
                </div>
                <.smart_rules_editor
                  conditions={@rules_conditions}
                  match_type={@rules_match_type}
                  sort_field={@rules_sort_field}
                  sort_direction={@rules_sort_direction}
                  limit={@rules_limit}
                />
              <% end %>
            </div>
          </.form>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_edit_modal">
              Cancel
            </button>
            <button type="submit" form="edit-collection-form" class="btn btn-primary">
              Save Changes
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
          <:title>Delete Collection?</:title>

          <p class="text-base-content/70">
            Are you sure you want to delete <strong>{@collection.name}</strong>?
            This action cannot be undone.
          </p>
          <p class="text-sm text-base-content/50 mt-2">
            The media items in this collection will not be deleted.
          </p>

          <:actions>
            <button type="button" class="btn btn-ghost" phx-click="close_delete_modal">
              Cancel
            </button>
            <button type="button" class="btn btn-error" phx-click="delete_collection">
              <.icon name="hero-trash" class="w-4 h-4" /> Delete Collection
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
          <:title>Add Items to Collection</:title>

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
                placeholder="Search movies or TV shows..."
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
                  <p class="font-medium">Search your library</p>
                  <p class="text-sm">Type at least 2 characters to search</p>
                </div>
              <% @add_items_results == [] -> %>
                <%!-- No results --%>
                <div class="flex flex-col items-center justify-center py-16 text-base-content/50">
                  <.icon name="hero-face-frown" class="w-16 h-16 mb-4 opacity-30" />
                  <p class="font-medium">No results found</p>
                  <p class="text-sm">Try a different search term</p>
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
                            {if item.type == "movie", do: "Movie", else: "TV Show"}
                          </span>
                        </div>
                      </div>

                      <%!-- Action indicator --%>
                      <div class="flex-shrink-0">
                        <%= if in_collection? do %>
                          <div class="btn btn-sm btn-success btn-outline gap-1">
                            <.icon name="hero-check" class="w-4 h-4" />
                            <span class="hidden sm:inline">Added</span>
                          </div>
                        <% else %>
                          <div class="btn btn-sm btn-ghost gap-1">
                            <.icon name="hero-plus" class="w-4 h-4" />
                            <span class="hidden sm:inline">Add</span>
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
              Done
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
        {:noreply, put_flash(socket, :error, "No playable items in this collection")}

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
           |> put_flash(:info, "Item removed from collection")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Item not found in collection")}

        {:error, :smart_collection} ->
          {:noreply, put_flash(socket, :error, "Cannot remove items from smart collections")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this collection")}
    end
  end

  def handle_event("open_edit_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_edit_modal, true)
      |> parse_existing_rules(socket.assigns.collection)

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
        json = build_smart_rules_json(full_params)
        {json, SmartRules.validate(json)}
      else
        {nil, {:ok, nil}}
      end

    # Validate smart rules before saving
    case validation_result do
      {:error, errors} ->
        error_msg = "Invalid smart rules: #{Enum.join(errors, ", ")}"
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
             |> put_flash(:info, "Collection updated")
             |> load_items(reset: true)}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, "You don't have permission to edit this collection")}

          {:error, :system_collection} ->
            {:noreply, put_flash(socket, :error, "System collections cannot be edited")}

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
         |> put_flash(:info, "Collection deleted")
         |> push_navigate(to: ~p"/collections")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to delete this collection")}

      {:error, :system_collection} ->
        {:noreply, put_flash(socket, :error, "System collections cannot be deleted")}
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
             |> put_flash(:info, "Item removed from collection")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to remove item")}
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
             |> put_flash(:info, "Item added to collection")}

          {:error, :smart_collection} ->
            {:noreply, put_flash(socket, :error, "Cannot add items to smart collections")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to add item")}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this collection")}
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
                "value" => cond["value"] || ""
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

  defp build_smart_rules_json(params) do
    # Get conditions from params
    conditions =
      case params["conditions"] do
        nil ->
          []

        cond_params when is_map(cond_params) ->
          cond_params
          |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
          |> Enum.map(fn {_, cond} ->
            value = parse_condition_value(cond["field"], cond["value"], cond["operator"])

            %{
              "field" => cond["field"],
              "operator" => cond["operator"],
              "value" => value
            }
          end)
          |> Enum.filter(fn c -> c["field"] != "" end)
      end

    match_type = params["match_type"] || "all"
    sort_field = params["sort_field"] || ""
    sort_direction = params["sort_direction"] || "desc"

    limit =
      case params["limit"] do
        nil -> nil
        "" -> nil
        val when is_binary(val) -> String.to_integer(val)
        val -> val
      end

    rules = %{
      "match_type" => match_type,
      "conditions" => conditions
    }

    # Add sort if specified
    rules =
      if sort_field && sort_field != "" do
        Map.put(rules, "sort", %{"field" => sort_field, "direction" => sort_direction})
      else
        rules
      end

    # Add limit if specified
    rules =
      if limit && limit > 0 do
        Map.put(rules, "limit", limit)
      else
        rules
      end

    Jason.encode!(rules)
  end

  # Fields that should always keep string values
  @string_fields ~w(category type title metadata.original_language metadata.status)

  # Fields that should be parsed as numbers
  @numeric_fields ~w(year metadata.vote_average)

  defp parse_condition_value(_field, value, operator)
       when operator in ["in", "not_in", "contains_any"] do
    # Split comma-separated values into a list
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp parse_condition_value(_field, value, "between") do
    # Parse "min, max" into [min, max]
    case String.split(value, ",") do
      [min, max] ->
        [parse_number(String.trim(min)), parse_number(String.trim(max))]

      _ ->
        value
    end
  end

  # String fields should always remain as strings
  defp parse_condition_value(field, value, _operator) when field in @string_fields do
    value
  end

  # Numeric fields should be parsed as numbers
  defp parse_condition_value(field, value, _operator) when field in @numeric_fields do
    parse_number(value)
  end

  # For monitored (boolean field)
  defp parse_condition_value("monitored", value, _operator) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      "1" -> true
      "0" -> false
      _ -> value
    end
  end

  # Default: try to parse as number, otherwise keep as string
  defp parse_condition_value(_field, value, _operator) do
    case Integer.parse(value) do
      {num, ""} -> num
      _ -> value
    end
  end

  defp parse_number(str) do
    case Integer.parse(str) do
      {num, ""} -> num
      _ -> str
    end
  end

  defp extract_changeset_error(changeset) do
    case changeset.errors do
      [{_field, {msg, _}} | _] -> msg
      _ -> "Failed to update collection"
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

  # Smart rules editor component
  attr :conditions, :list, required: true
  attr :match_type, :string, required: true
  attr :sort_field, :string, required: true
  attr :sort_direction, :string, required: true
  attr :limit, :any, required: true

  defp smart_rules_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Conditions Card --%>
      <div class="card bg-base-200/50 border border-base-300">
        <div class="card-body p-4">
          <%!-- Header with match type and add button --%>
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-secondary/20">
                <.icon name="hero-funnel" class="w-4 h-4 text-secondary" />
              </div>
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium">Match</span>
                <select name="match_type" class="select select-sm select-bordered bg-base-100">
                  <option value="all" selected={@match_type == "all"}>all conditions</option>
                  <option value="any" selected={@match_type == "any"}>any condition</option>
                </select>
              </div>
            </div>
            <button
              type="button"
              phx-click="add_condition"
              class="btn btn-sm btn-secondary btn-outline gap-1"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Add
            </button>
          </div>

          <%!-- Conditions List --%>
          <div class="space-y-2">
            <%= for {condition, index} <- Enum.with_index(@conditions) do %>
              <div class="flex items-center gap-2 p-3 bg-base-100 rounded-lg border border-base-300 shadow-sm">
                <%!-- Condition number badge --%>
                <div class="badge badge-sm badge-ghost font-mono w-6 h-6 flex-shrink-0">
                  {index + 1}
                </div>

                <%!-- Field selector --%>
                <select
                  name={"conditions[#{index}][field]"}
                  class="select select-sm select-bordered flex-1 min-w-0 bg-base-100"
                >
                  <option value="">Select field...</option>
                  <optgroup label="Basic">
                    <option value="category" selected={condition["field"] == "category"}>
                      Category
                    </option>
                    <option value="type" selected={condition["field"] == "type"}>Type</option>
                    <option value="year" selected={condition["field"] == "year"}>Year</option>
                    <option value="title" selected={condition["field"] == "title"}>Title</option>
                    <option value="monitored" selected={condition["field"] == "monitored"}>
                      Monitored
                    </option>
                  </optgroup>
                  <optgroup label="Metadata">
                    <option
                      value="metadata.vote_average"
                      selected={condition["field"] == "metadata.vote_average"}
                    >
                      Rating
                    </option>
                    <option value="metadata.genres" selected={condition["field"] == "metadata.genres"}>
                      Genre
                    </option>
                    <option
                      value="metadata.original_language"
                      selected={condition["field"] == "metadata.original_language"}
                    >
                      Language
                    </option>
                    <option value="metadata.status" selected={condition["field"] == "metadata.status"}>
                      Status
                    </option>
                  </optgroup>
                  <optgroup label="Dates">
                    <option value="inserted_at" selected={condition["field"] == "inserted_at"}>
                      Date Added
                    </option>
                  </optgroup>
                </select>

                <%!-- Operator selector --%>
                <.condition_operator_select
                  field={condition["field"]}
                  operator={condition["operator"]}
                  index={index}
                />

                <%!-- Value input --%>
                <.condition_value_input
                  field={condition["field"]}
                  operator={condition["operator"]}
                  value={condition["value"]}
                  index={index}
                />

                <%!-- Remove button --%>
                <button
                  type="button"
                  phx-click="remove_condition"
                  phx-value-index={index}
                  class={[
                    "btn btn-ghost btn-sm btn-square text-base-content/50 hover:text-error hover:bg-error/10",
                    length(@conditions) <= 1 && "btn-disabled opacity-30"
                  ]}
                  title="Remove condition"
                  disabled={length(@conditions) <= 1}
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Sort & Limit Card --%>
      <div class="card bg-base-200/50 border border-base-300">
        <div class="card-body p-4">
          <div class="flex items-center gap-3 mb-3">
            <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-primary/20">
              <.icon name="hero-arrows-up-down" class="w-4 h-4 text-primary" />
            </div>
            <span class="text-sm font-medium">Sort & Limit</span>
            <span class="text-xs text-base-content/50">(Optional)</span>
          </div>

          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <%!-- Sort by --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Sort by</span>
              </label>
              <select name="sort_field" class="select select-sm select-bordered bg-base-100 w-full">
                <option value="" selected={@sort_field == ""}>Default order</option>
                <option value="title" selected={@sort_field == "title"}>Title</option>
                <option value="year" selected={@sort_field == "year"}>Year</option>
                <option value="rating" selected={@sort_field == "rating"}>Rating</option>
                <option value="added_date" selected={@sort_field == "added_date"}>Date Added</option>
              </select>
            </div>

            <%!-- Direction --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Direction</span>
              </label>
              <select
                name="sort_direction"
                class="select select-sm select-bordered bg-base-100 w-full"
              >
                <option value="asc" selected={@sort_direction == "asc"}>Ascending</option>
                <option value="desc" selected={@sort_direction == "desc"}>Descending</option>
              </select>
            </div>

            <%!-- Limit --%>
            <div class="form-control">
              <label class="label py-1">
                <span class="label-text text-xs">Max items</span>
              </label>
              <input
                type="number"
                name="limit"
                min="0"
                max="1000"
                placeholder="No limit"
                value={@limit}
                class="input input-sm input-bordered bg-base-100 w-full"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  alias Mydia.Collections.SmartRulesFields

  defp value_placeholder("in"), do: "value1, value2, ..."
  defp value_placeholder("not_in"), do: "value1, value2, ..."
  defp value_placeholder("contains_any"), do: "value1, value2, ..."
  defp value_placeholder("between"), do: "min, max"
  defp value_placeholder(_), do: "Value..."

  # Condition operator selector - data-driven from SmartRulesFields
  attr :field, :string, required: true
  attr :operator, :string, required: true
  attr :index, :integer, required: true

  defp condition_operator_select(assigns) do
    operators = SmartRulesFields.get_operators(assigns.field)
    labels = SmartRulesFields.operator_labels()

    # Special labels for date fields
    date_labels =
      if assigns.field == "inserted_at" do
        %{gt: "after", gte: "on or after", lt: "before", lte: "on or before"}
      else
        %{}
      end

    assigns =
      assigns
      |> assign(:operators, operators)
      |> assign(:labels, Map.merge(labels, date_labels))

    ~H"""
    <select name={"conditions[#{@index}][operator]"} class="select select-sm select-bordered w-32">
      <%= for op <- @operators do %>
        <option value={op} selected={@operator == to_string(op)}>
          {Map.get(@labels, op, to_string(op))}
        </option>
      <% end %>
    </select>
    """
  end

  # Condition value input - data-driven from SmartRulesFields
  attr :field, :string, required: true
  attr :operator, :string, required: true
  attr :value, :any, required: true
  attr :index, :integer, required: true

  defp condition_value_input(assigns) do
    field_def = SmartRulesFields.get_field(assigns.field)
    render_value_input(assigns, field_def)
  end

  # Enum fields - render dropdown with values from database
  defp render_value_input(assigns, %{type: :enum} = field_def) do
    values = field_def.values.()
    assigns = assign(assigns, :options, values)

    ~H"""
    <select
      name={"conditions[#{@index}][value]"}
      class="select select-sm select-bordered flex-1 min-w-0"
    >
      <option value="">Select...</option>
      <%= for {val, label} <- @options do %>
        <option value={val} selected={@value == val or @value == to_string(val)}>{label}</option>
      <% end %>
    </select>
    """
  end

  # Boolean fields - render yes/no dropdown
  defp render_value_input(assigns, %{type: :boolean} = field_def) do
    values = field_def.values.()
    assigns = assign(assigns, :options, values)

    ~H"""
    <select
      name={"conditions[#{@index}][value]"}
      class="select select-sm select-bordered flex-1 min-w-0"
    >
      <option value="">Select...</option>
      <%= for {val, label} <- @options do %>
        <option value={val} selected={@value == val or @value == String.to_atom(val)}>{label}</option>
      <% end %>
    </select>
    """
  end

  # Number fields with "between" operator - render text input for range
  defp render_value_input(%{operator: "between"} = assigns, %{type: :number} = field_def) do
    placeholder =
      if field_def[:input_opts][:step] do
        "e.g. 7.0, 9.0"
      else
        "e.g. 2000, 2024"
      end

    assigns = assign(assigns, :placeholder, placeholder)

    ~H"""
    <input
      type="text"
      name={"conditions[#{@index}][value]"}
      value={@value}
      class="input input-sm input-bordered flex-1 min-w-0"
      placeholder={@placeholder}
    />
    """
  end

  # Number fields - render number input
  defp render_value_input(assigns, %{type: :number} = field_def) do
    opts = Map.get(field_def, :input_opts, %{})

    assigns =
      assigns
      |> assign(:min, Map.get(opts, :min, 1900))
      |> assign(:max, Map.get(opts, :max, 2100))
      |> assign(:step, Map.get(opts, :step, 1))

    ~H"""
    <input
      type="number"
      name={"conditions[#{@index}][value]"}
      value={@value}
      min={@min}
      max={@max}
      step={@step}
      class="input input-sm input-bordered flex-1 min-w-0"
    />
    """
  end

  # Date fields - render date input
  defp render_value_input(assigns, %{type: :date}) do
    assigns = assign(assigns, :formatted_value, format_date_value(assigns.value))

    ~H"""
    <input
      type="date"
      name={"conditions[#{@index}][value]"}
      value={@formatted_value}
      class="input input-sm input-bordered flex-1 min-w-0"
    />
    """
  end

  # Text fields and fallback - render text input
  defp render_value_input(assigns, _field_def) do
    ~H"""
    <input
      type="text"
      name={"conditions[#{@index}][value]"}
      value={@value}
      class="input input-sm input-bordered flex-1 min-w-0"
      placeholder={value_placeholder(@operator)}
    />
    """
  end

  defp format_date_value(nil), do: ""
  defp format_date_value(""), do: ""

  defp format_date_value(value) when is_binary(value) do
    if String.match?(value, ~r/^\d{4}-\d{2}-\d{2}/) do
      String.slice(value, 0, 10)
    else
      value
    end
  end

  defp format_date_value(_), do: ""

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

  defp type_badge_class("smart"), do: "badge-secondary"
  defp type_badge_class("manual"), do: "badge-primary"
  defp type_badge_class(_), do: "badge-ghost"

  defp type_icon("smart"), do: "hero-sparkles"
  defp type_icon("manual"), do: "hero-folder"
  defp type_icon(_), do: "hero-folder"

  defp type_label("smart"), do: "Smart"
  defp type_label("manual"), do: "Manual"
  defp type_label(_), do: "Manual"
end
