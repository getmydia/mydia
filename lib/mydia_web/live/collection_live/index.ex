defmodule MydiaWeb.CollectionLive.Index do
  @moduledoc """
  LiveView for browsing and managing collections.

  Supports:
  - Grid/list view toggle
  - Filtering by collection type and visibility
  - Creating new collections via modal with UI-based rules builder
  - Navigation to collection detail
  """
  use MydiaWeb, :live_view

  alias Mydia.Collections
  alias Mydia.Collections.Collection

  import MydiaWeb.CollectionLive.Components, only: [smart_rules_editor: 1, load_value_options: 1]

  @default_condition %{"field" => "", "operator" => "eq", "value" => ""}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> assign(:search_query, "")
     |> assign(:filter_type, nil)
     |> assign(:filter_visibility, nil)
     |> assign(:show_new_modal, false)
     |> assign(:new_collection_type, "manual")
     |> assign(:new_form, to_form(%{}, as: :collection))
     |> assign(:collections_empty?, true)
     |> assign_default_rules()
     |> stream(:collections, [])}
  end

  defp assign_default_rules(socket) do
    socket
    |> assign(:rules_conditions, [@default_condition])
    |> assign(:rules_match_type, "all")
    |> assign(:rules_sort_field, "")
    |> assign(:rules_sort_direction, "desc")
    |> assign(:rules_limit, nil)
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Collections")
     |> load_collections()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <div class="container mx-auto px-4 py-6">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
          <div>
            <h1 class="text-2xl font-bold">Collections</h1>
            <p class="text-base-content/60">Organize your media into custom groups</p>
          </div>
          <div class="flex items-center gap-2">
            <.view_mode_toggle view_mode={@view_mode} />
            <button
              type="button"
              class="btn btn-primary gap-2"
              phx-click="open_new_modal"
            >
              <.icon name="hero-plus" class="w-5 h-5" /> New Collection
            </button>
          </div>
        </div>

        <%!-- Filters --%>
        <.collection_filters
          search_query={@search_query}
          filter_type={@filter_type}
          filter_visibility={@filter_visibility}
        />

        <%!-- Collections Grid/List --%>
        <%= if @view_mode == :grid do %>
          <.collection_grid id="collections-grid" collections={@streams.collections}>
            <:collection :let={collection}>
              <.collection_card
                collection={collection}
                href={~p"/collections/#{collection.id}"}
                item_count={collection.item_count || 0}
                poster_paths={collection.poster_paths || []}
                on_play="play_collection"
                can_edit={can_edit?(collection, @current_user)}
              />
            </:collection>
          </.collection_grid>
        <% else %>
          <.collection_list id="collections-list" collections={@streams.collections}>
            <:collection :let={collection}>
              <.collection_row
                collection={collection}
                href={~p"/collections/#{collection.id}"}
                item_count={collection.item_count || 0}
                poster_paths={collection.poster_paths || []}
                on_play="play_collection"
                can_edit={can_edit?(collection, @current_user)}
              />
            </:collection>
          </.collection_list>
        <% end %>

        <%!-- Empty state --%>
        <div
          :if={@collections_empty?}
          class="text-center py-12"
          id="empty-state"
        >
          <.collection_empty_state message="No collections found">
            <:actions>
              <button
                type="button"
                class="btn btn-primary gap-2"
                phx-click="open_new_modal"
              >
                <.icon name="hero-plus" class="w-5 h-5" /> Create your first collection
              </button>
            </:actions>
          </.collection_empty_state>
        </div>

        <%!-- New Collection Modal --%>
        <.modal
          :if={@show_new_modal}
          id="new-collection-modal"
          show={@show_new_modal}
          on_cancel={JS.push("close_new_modal")}
        >
          <:title>
            <div class="flex items-center gap-3">
              <div class="flex items-center justify-center w-10 h-10 rounded-xl bg-primary/20">
                <.icon name="hero-folder-plus" class="w-5 h-5 text-primary" />
              </div>
              <div>
                <div class="font-bold text-lg">Create Collection</div>
                <div class="text-xs text-base-content/60 font-normal">
                  Organize your media into groups
                </div>
              </div>
            </div>
          </:title>

          <.form
            for={@new_form}
            phx-submit="create_collection"
            phx-change="validate_collection"
            id="new-collection-form"
          >
            <div class="space-y-3">
              <%!-- Collection Type --%>
              <.type_selector
                selected={@new_collection_type}
                name="collection[type]"
              />

              <%!-- Name & Visibility Row --%>
              <div class={["grid gap-3", @current_user.role == "admin" && "grid-cols-2"]}>
                <div class="form-control">
                  <label class="label py-1">
                    <span class="label-text text-sm font-medium">Name</span>
                  </label>
                  <input
                    type="text"
                    name="collection[name]"
                    value={@new_form[:name].value}
                    class="input input-sm input-bordered w-full"
                    placeholder="My Collection"
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
                      <option value="private" selected={@new_form[:visibility].value != "shared"}>
                        Private
                      </option>
                      <option value="shared" selected={@new_form[:visibility].value == "shared"}>
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
                  value={@new_form[:description].value}
                  class="input input-sm input-bordered w-full"
                  placeholder="What's this collection about?"
                />
              </div>

              <%!-- Smart Rules Builder (shown for smart collections) --%>
              <%= if @new_collection_type == "smart" do %>
                <div class="divider my-2 text-xs text-base-content/50">
                  <.icon name="hero-sparkles" class="w-4 h-4" /> Smart Rules
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
            <button type="button" class="btn btn-ghost" phx-click="close_new_modal">
              Cancel
            </button>
            <button type="submit" form="new-collection-form" class="btn btn-primary">
              <.icon name="hero-plus" class="w-4 h-4" /> Create Collection
            </button>
          </:actions>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)
    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_collections()}
  end

  def handle_event("filter", params, socket) do
    filter_type =
      case params["type"] do
        "" -> nil
        type when type in ["manual", "smart"] -> type
        _ -> nil
      end

    filter_visibility =
      case params["visibility"] do
        "" -> nil
        vis when vis in ["private", "shared"] -> vis
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_type, filter_type)
     |> assign(:filter_visibility, filter_visibility)
     |> load_collections()}
  end

  def handle_event("open_new_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_modal, true)
     |> assign(:new_collection_type, "manual")
     |> assign(:new_form, to_form(%{}, as: :collection))
     |> assign_default_rules()}
  end

  def handle_event("close_new_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_modal, false)}
  end

  alias MydiaWeb.MediaLive.Show.Helpers, as: PlayerHelpers

  def handle_event("play_collection", %{"id" => collection_id}, socket) do
    user = socket.assigns.current_user

    case Collections.get_collection(user, collection_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Collection not found")}

      collection ->
        # Get all playable items from the collection
        playable_items = Collections.get_playable_items(collection)

        case playable_items do
          [] ->
            {:noreply, put_flash(socket, :error, "No playable items in this collection")}

          items ->
            # Build the queue player URL and redirect
            queue_url = PlayerHelpers.flutter_queue_player_url(items)
            {:noreply, redirect(socket, external: queue_url)}
        end
    end
  end

  def handle_event("validate_collection", %{"collection" => params} = full_params, socket) do
    new_type = params["type"] || socket.assigns.new_collection_type

    socket =
      socket
      |> assign(:new_collection_type, new_type)
      |> assign(:new_form, to_form(params, as: :collection))

    socket = if new_type == "smart", do: load_value_options(socket), else: socket

    # Update rules from form params
    socket = update_rules_from_params(socket, full_params)

    {:noreply, socket}
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

  def handle_event("create_collection", %{"collection" => params} = full_params, socket) do
    user = socket.assigns.current_user
    collection_type = params["type"] || "manual"

    # Build smart_rules JSON for smart collections
    smart_rules =
      if collection_type == "smart" do
        build_smart_rules_json(socket, full_params)
      else
        nil
      end

    attrs = %{
      name: params["name"],
      description: params["description"],
      type: collection_type,
      visibility: params["visibility"] || "private",
      smart_rules: smart_rules
    }

    case Collections.create_collection(user, attrs) do
      {:ok, collection} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collection created successfully")
         |> assign(:show_new_modal, false)
         |> push_navigate(to: ~p"/collections/#{collection.id}")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to create shared collections")}

      {:error, %Ecto.Changeset{} = changeset} ->
        error_msg = extract_changeset_error(changeset)

        {:noreply,
         socket
         |> put_flash(:error, error_msg)
         |> assign(:new_form, to_form(changeset, as: :collection))}
    end
  end

  defp update_rules_from_params(socket, params) do
    # Update match_type
    match_type = params["match_type"] || socket.assigns.rules_match_type

    # Update conditions from form params
    conditions =
      case params["conditions"] do
        nil ->
          socket.assigns.rules_conditions

        cond_params when is_map(cond_params) ->
          cond_params
          |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
          |> Enum.map(fn {_, cond} ->
            %{
              "field" => cond["field"] || "",
              "operator" => cond["operator"] || "eq",
              "value" => cond["value"] || ""
            }
          end)
      end

    # Update sort options
    sort_field = params["sort_field"] || socket.assigns.rules_sort_field
    sort_direction = params["sort_direction"] || socket.assigns.rules_sort_direction

    # Update limit
    limit =
      case params["limit"] do
        nil -> socket.assigns.rules_limit
        "" -> nil
        val when is_binary(val) -> String.to_integer(val)
        val -> val
      end

    socket
    |> assign(:rules_match_type, match_type)
    |> assign(:rules_conditions, conditions)
    |> assign(:rules_sort_field, sort_field)
    |> assign(:rules_sort_direction, sort_direction)
    |> assign(:rules_limit, limit)
  end

  defp build_smart_rules_json(socket, params) do
    # Get conditions from params or socket
    conditions =
      case params["conditions"] do
        nil ->
          socket.assigns.rules_conditions

        cond_params when is_map(cond_params) ->
          cond_params
          |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
          |> Enum.map(fn {_, cond} ->
            value = parse_condition_value(cond["value"], cond["operator"])

            %{
              "field" => cond["field"],
              "operator" => cond["operator"],
              "value" => value
            }
          end)
          |> Enum.filter(fn c -> c["field"] != "" end)
      end

    match_type = params["match_type"] || socket.assigns.rules_match_type
    sort_field = params["sort_field"] || socket.assigns.rules_sort_field
    sort_direction = params["sort_direction"] || socket.assigns.rules_sort_direction

    limit =
      case params["limit"] do
        nil -> socket.assigns.rules_limit
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

  defp parse_condition_value(value, operator) when operator in ["in", "not_in", "contains_any"] do
    # Split comma-separated values into a list
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp parse_condition_value(value, "between") do
    # Parse "min, max" into [min, max]
    case String.split(value, ",") do
      [min, max] ->
        [parse_number(String.trim(min)), parse_number(String.trim(max))]

      _ ->
        value
    end
  end

  defp parse_condition_value(value, _operator) do
    # Try to parse as number, otherwise keep as string
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
      _ -> "Failed to create collection"
    end
  end

  # Private helpers

  defp load_collections(socket) do
    user = socket.assigns.current_user

    opts =
      []
      |> maybe_add_filter(:type, socket.assigns.filter_type)
      |> maybe_add_filter(:visibility, socket.assigns.filter_visibility)

    collections =
      user
      |> Collections.list_collections(opts)
      |> filter_by_search(socket.assigns.search_query)
      |> Enum.map(&add_item_count/1)
      |> Enum.map(&add_poster_paths/1)

    socket
    |> assign(:collections_empty?, collections == [])
    |> stream(:collections, collections, reset: true)
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp filter_by_search(collections, ""), do: collections
  defp filter_by_search(collections, nil), do: collections

  defp filter_by_search(collections, query) do
    query = String.downcase(query)

    Enum.filter(collections, fn collection ->
      String.contains?(String.downcase(collection.name), query)
    end)
  end

  defp add_item_count(%Collection{} = collection) do
    count = Collections.item_count(collection)
    Map.put(collection, :item_count, count)
  end

  defp add_poster_paths(%Collection{} = collection) do
    paths = Collections.poster_paths(collection, 4)
    Map.put(collection, :poster_paths, paths)
  end

  defp can_edit?(%Collection{user_id: user_id}, %{id: current_user_id}) do
    user_id == current_user_id
  end
end
