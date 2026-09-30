defmodule MydiaWeb.DashboardLive.RegionalComponents do
  @moduledoc "The Home widget showing what's playing in the user's country."
  use MydiaWeb, :html

  import MydiaWeb.DiscoverComponents
  import MydiaWeb.PosterCardComponents

  alias Mydia.Metadata.Countries
  alias Mydia.Metadata.RegionalSources

  attr :country, :string, default: nil
  attr :sources, :list, required: true
  attr :selected, :string, default: nil
  attr :status, :atom, required: true
  attr :items, :list, required: true
  attr :current_user, :map, required: true
  attr :adding_ids, MapSet, required: true
  attr :requesting_item_id, :string, default: nil
  attr :rail_limit, :integer, required: true

  def regional_widget(assigns) do
    ~H"""
    <div id="regional-widget" class="mb-6 md:mb-8">
      <%= if is_nil(@country) do %>
        <div class="card bg-base-200">
          <div class="card-body flex-row items-center justify-between gap-4 py-4">
            <p>Set your country to see what's playing near you.</p>
            <.link id="regional-set-country" navigate={~p"/discover"} class="btn btn-sm btn-primary">
              Choose country
            </.link>
          </div>
        </div>
      <% else %>
        <div class="flex items-center justify-between gap-3 mb-3">
          <h2 class="text-lg md:text-xl font-semibold truncate">
            <span aria-hidden="true">{Countries.flag(@country)}</span> In {Countries.name(@country)}
          </h2>
          <.link
            :if={@selected}
            id="regional-view-all"
            navigate={
              ~p"/discover?#{%{"type" => "movie", "category" => "home", "source" => @selected}}"
            }
            class="btn btn-sm btn-ghost"
          >
            View All <.icon name="hero-arrow-right" class="w-4 h-4 ml-1" />
          </.link>
        </div>
        <div id="regional-chips" class="flex flex-wrap gap-2 mb-3">
          <button
            :for={source <- @sources}
            id={"regional-chip-#{RegionalSources.to_param(source)}"}
            type="button"
            phx-click="select_regional_source"
            phx-value-source={RegionalSources.to_param(source)}
            class={[
              "btn btn-sm",
              if(RegionalSources.to_param(source) == @selected, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {chip_label(source)}
          </button>
        </div>
        <%= case @status do %>
          <% :error -> %>
            <div id="regional-error" class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>Could not load these titles right now.</span>
            </div>
          <% :ok when @items == [] -> %>
            <p class="text-sm text-base-content/60 py-4">Nothing here right now.</p>
          <% :ok -> %>
            <.media_rail
              id="regional-rail"
              title=""
              show_header={false}
              items={@items}
              media_type={:movie}
              current_user={@current_user}
              adding_ids={@adding_ids}
              requesting_item_id={@requesting_item_id}
            />
          <% _loading -> %>
            <.poster_card_rail_skeleton id="regional-skeleton" count={@rail_limit} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # Chips are short: the service name alone, not "Latest on ...".
  defp chip_label({:service, _id, name}), do: name
  defp chip_label(source), do: RegionalSources.label(source, nil)
end
