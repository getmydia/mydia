defmodule MydiaWeb.DiscoverComponents do
  @moduledoc """
  Shared components for media discovery/trending cards used across
  Dashboard and Discover pages.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  alias Mydia.Metadata.ImageUrl
  alias MydiaWeb.LibraryComponents

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  @doc """
  Renders a trending media card with poster, status badge, title, year,
  and an action button (Add to Library / Request / Go to Movie/Show).

  ## Attributes

    * `item` - enriched search result map with `in_library`, `monitored`,
      `id`, `provider_id`, `poster_path`, `title`, `year` fields.
    * `media_type` - `:movie` or `:tv_show`.
    * `current_user` - current user struct (for guest vs admin logic).
    * `adding_item_id` - provider_id (string) of the item currently being added.
  """
  attr :item, :map, required: true
  attr :media_type, :atom, required: true
  attr :current_user, :map, required: true
  attr :adding_item_id, :string, default: nil
  attr :requesting_item_id, :string, default: nil
  attr :libraries, :list, default: []

  def trending_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow relative overflow-hidden">
      <%= if (vote = Map.get(@item, :vote_average)) && vote > 0 do %>
        <div class="absolute top-2 left-2 z-10">
          <div class="badge badge-warning gap-1 shadow-md">
            <.icon name="hero-star-solid" class="w-3 h-3" />
            <span class="text-xs">{Float.round(vote / 1, 1)}</span>
          </div>
        </div>
      <% end %>
      <%= if @item.in_library do %>
        <div class="absolute top-2 right-2 z-10">
          <%= if @item.monitored do %>
            <div class="w-6 h-6 rounded-full bg-success flex items-center justify-center shadow-md">
              <.icon name="hero-check-mini" class="w-4 h-4 text-success-content" />
            </div>
          <% else %>
            <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center shadow-md">
              <.icon name="hero-minus-small" class="w-4 h-4 text-base-content/60" />
            </div>
          <% end %>
        </div>
      <% end %>
      <figure
        class="aspect-[2/3] bg-base-300 cursor-pointer"
        phx-click="show_details"
        phx-value-id={@item.provider_id}
        phx-value-type={@media_type}
      >
        <%= if @item.poster_path do %>
          <img
            src={ImageUrl.poster_url(@item.poster_path)}
            alt={@item.title}
            class="w-full h-full object-cover"
          />
        <% else %>
          <div class="flex items-center justify-center w-full h-full">
            <.icon
              name={if(@media_type == :movie, do: "hero-film", else: "hero-tv")}
              class="w-16 h-16 text-base-content/20"
            />
          </div>
        <% end %>
      </figure>
      <div class="card-body p-3">
        <h3 class="font-semibold text-sm line-clamp-2" title={@item.title}>
          {@item.title}
        </h3>
        <%= if @item.year do %>
          <p class="text-xs text-base-content/60">{@item.year}</p>
        <% end %>
        <.trending_card_action
          item={@item}
          media_type={@media_type}
          current_user={@current_user}
          adding_item_id={@adding_item_id}
          requesting_item_id={@requesting_item_id}
          libraries={@libraries}
        />
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :media_type, :atom, required: true
  attr :current_user, :map, required: true
  attr :adding_item_id, :string, default: nil
  attr :requesting_item_id, :string, default: nil
  attr :libraries, :list, default: []

  defp trending_card_action(assigns) do
    ~H"""
    <%= if not @item.in_library do %>
      <%= if @current_user && @current_user.role == "guest" do %>
        <button
          phx-click="request_media"
          phx-value-tmdb_id={@item.provider_id}
          phx-value-media_type={@media_type}
          disabled={requested?(@item) or requesting?(@item, @requesting_item_id)}
          class="btn btn-primary btn-sm mt-2 w-full"
        >
          <%= cond do %>
            <% requesting?(@item, @requesting_item_id) -> %>
              <span class="loading loading-spinner loading-xs"></span> Requesting...
            <% requested?(@item) -> %>
              <.icon name="hero-check" class="w-4 h-4" /> Requested
            <% true -> %>
              <.icon name="hero-paper-airplane" class="w-4 h-4" /> Request
          <% end %>
        </button>
      <% else %>
        <div class="join w-full mt-2">
          <button
            phx-click="add_to_library"
            phx-value-tmdb_id={@item.provider_id}
            phx-value-media_type={@media_type}
            disabled={@adding_item_id == to_string(@item.provider_id)}
            class="btn btn-primary btn-sm join-item flex-1"
          >
            <%= if @adding_item_id == to_string(@item.provider_id) do %>
              <span class="loading loading-spinner loading-xs"></span> Adding...
            <% else %>
              <.icon name="hero-plus" class="w-4 h-4" /> Add to Library
            <% end %>
          </button>
          <LibraryComponents.library_picker_menu
            libraries={@libraries}
            event="add_to_library"
            tmdb_id={@item.provider_id}
            media_type={@media_type}
          />
        </div>
      <% end %>
    <% else %>
      <.link navigate={library_path(@media_type, @item.id)} class="btn btn-ghost btn-sm mt-2 w-full">
        <.icon name="hero-arrow-right" class="w-4 h-4" />
        {if(@media_type == :movie, do: "Go to Movie", else: "Go to Show")}
      </.link>
    <% end %>
    """
  end

  defp requested?(item), do: Map.get(item, :request_status) != nil

  defp requesting?(item, requesting_item_id),
    do: requesting_item_id != nil and requesting_item_id == to_string(item.provider_id)

  defp library_path(:movie, id), do: "/movies/#{id}"
  defp library_path(:tv_show, id), do: "/tv/#{id}"
end
