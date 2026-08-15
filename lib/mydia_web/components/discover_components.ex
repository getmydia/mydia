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
  attr :on_select, :string, default: "show_details"
  attr :navigate, :string, default: nil

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
      <%= cond do %>
        <% @navigate -> %>
          <.link navigate={@navigate} class="block">
            <figure class="aspect-[2/3] bg-base-300 cursor-pointer">
              <.card_poster item={@item} media_type={@media_type} />
            </figure>
          </.link>
        <% @on_select -> %>
          <figure
            class="aspect-[2/3] bg-base-300 cursor-pointer"
            phx-click={@on_select}
            phx-value-id={@item.provider_id}
            phx-value-type={@media_type}
          >
            <.card_poster item={@item} media_type={@media_type} />
          </figure>
        <% true -> %>
          <figure class="aspect-[2/3] bg-base-300">
            <.card_poster item={@item} media_type={@media_type} />
          </figure>
      <% end %>
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

  @doc """
  Renders a horizontal strip of recommended titles.

  Reuses `trending_card/1` so an owned title carries the same badge and an unowned
  one the same add-or-request action as it would on the Discover grid. The strip
  renders nothing at all when `items` is empty, which is the designed behaviour for
  a title TMDB has no recommendations for.

  An item may carry a `:navigate` key. When it does, that card's poster becomes a
  link instead of a click target, which is how an owned title on the media detail
  page reaches its own page from a LiveView that has no `show_details` handler.
  """
  attr :items, :list, required: true
  attr :media_type, :atom, required: true
  attr :current_user, :map, required: true
  attr :adding_item_id, :string, default: nil
  attr :requesting_item_id, :string, default: nil
  attr :libraries, :list, default: []
  attr :id, :string, default: "recommendations-rail"
  attr :title, :string, default: "More like this"
  attr :on_select, :string, default: "show_details"

  def recommendations_rail(assigns) do
    ~H"""
    <div :if={@items != []} id={@id} class="mb-6 md:mb-8">
      <h2 class="text-lg md:text-xl font-semibold mb-3">{@title}</h2>

      <div class="flex gap-3 overflow-x-auto snap-x scroll-smooth pb-2">
        <div :for={item <- @items} class="snap-start flex-shrink-0 w-36">
          <.trending_card
            item={item}
            media_type={@media_type}
            current_user={@current_user}
            adding_item_id={@adding_item_id}
            requesting_item_id={@requesting_item_id}
            libraries={@libraries}
            on_select={@on_select}
            navigate={Map.get(item, :navigate)}
          />
        </div>
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

  attr :item, :map, required: true
  attr :media_type, :atom, required: true

  defp card_poster(assigns) do
    ~H"""
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
    """
  end
end
