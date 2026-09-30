defmodule MydiaWeb.DiscoverLive.RegionalComponents do
  @moduledoc "The Discover country tab: landing rows and the services picker."
  use MydiaWeb, :html

  import MydiaWeb.DiscoverComponents
  import MydiaWeb.PosterCardComponents

  alias Mydia.Metadata.RegionalSources

  attr :sources, :list, required: true
  attr :rows, :map, required: true
  attr :country, :string, required: true
  attr :media_type, :atom, required: true
  attr :has_services, :boolean, required: true
  attr :hide_owned, :boolean, required: true
  attr :current_user, :map, required: true
  attr :adding_ids, MapSet, required: true
  attr :requesting_item_id, :string, default: nil

  def regional_rows(assigns) do
    ~H"""
    <div id="discover-regional-rows" class="space-y-2">
      <%= for source <- @sources do %>
        <% param = RegionalSources.to_param(source) %>
        <% row = Map.get(@rows, param, %{status: :loading, items: []}) %>
        <% items = if @hide_owned, do: Enum.reject(row.items, & &1.in_library), else: row.items %>
        <div
          :if={source == :made_here and not @has_services}
          id="discover-services-prompt"
          class="card bg-base-200 mb-6"
        >
          <div class="card-body flex-row items-center justify-between gap-4 py-4">
            <div>
              <h2 class="font-semibold">Pick your streaming services</h2>
              <p class="text-sm text-base-content/60">
                See the latest titles on the services you subscribe to.
              </p>
            </div>
            <button
              id="discover-services-prompt-open"
              class="btn btn-primary btn-sm"
              phx-click="open_services_picker"
            >
              Pick services
            </button>
          </div>
        </div>
        <section id={"discover-row-#{param}"} class="mb-6 md:mb-8">
          <div class="flex items-center justify-between gap-3 mb-3">
            <h2 class="text-lg md:text-xl font-semibold truncate">
              {RegionalSources.label(source, @country)}
            </h2>
            <.link
              id={"discover-row-#{param}-see-all"}
              patch={
                ~p"/discover?#{%{"type" => @media_type, "category" => "home", "source" => param}}"
              }
              class="btn btn-sm btn-ghost"
            >
              See all <.icon name="hero-arrow-right" class="w-4 h-4 ml-1" />
            </.link>
          </div>
          <%= case row.status do %>
            <% :loading -> %>
              <.poster_card_rail_skeleton id={"discover-row-#{param}-skeleton"} count={10} />
            <% :error -> %>
              <div class="alert">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-warning" />
                <span>Could not load this row.</span>
                <button
                  id={"discover-row-#{param}-retry"}
                  class="btn btn-sm"
                  phx-click="retry_regional_row"
                  phx-value-source={param}
                >
                  Retry
                </button>
              </div>
            <% :ok when items == [] -> %>
              <p id={"discover-row-#{param}-empty"} class="text-sm text-base-content/60 py-4">
                Nothing here right now.
              </p>
            <% :ok -> %>
              <.media_rail
                id={"discover-row-#{param}-rail"}
                show_header={false}
                title={RegionalSources.label(source, @country)}
                items={items}
                media_type={@media_type}
                current_user={@current_user}
                adding_ids={@adding_ids}
                requesting_item_id={@requesting_item_id}
              />
          <% end %>
        </section>
      <% end %>
    </div>
    """
  end

  attr :picker, :map, required: true
  attr :saved_ids, :list, required: true

  def services_picker(assigns) do
    ~H"""
    <div id="discover-services-picker" class="modal modal-open" role="dialog">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg">Your streaming services</h3>
        <p class="text-sm text-base-content/60 mt-1">
          Pick the services you subscribe to. Each gets a row of its latest titles.
        </p>
        <%= case @picker.status do %>
          <% :loading -> %>
            <div class="flex justify-center py-10">
              <span class="loading loading-spinner loading-md text-primary"></span>
            </div>
          <% :error -> %>
            <div class="alert alert-warning mt-4">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>Could not load the services for your country.</span>
              <button
                id="discover-services-retry"
                class="btn btn-sm"
                phx-click="retry_services_picker"
              >
                Retry
              </button>
            </div>
          <% :ok -> %>
            <form id="discover-services-form" phx-submit="save_services" class="mt-4">
              <div class="filter flex flex-wrap gap-2">
                <input
                  :for={provider <- @picker.providers}
                  type="checkbox"
                  name="services[]"
                  value={provider.id}
                  class="btn btn-sm"
                  aria-label={provider.name}
                  checked={provider.id in @saved_ids}
                />
              </div>
              <div class="modal-action">
                <button type="button" class="btn btn-ghost" phx-click="close_services_picker">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Save</button>
              </div>
            </form>
        <% end %>
      </div>
      <div class="modal-backdrop" phx-click="close_services_picker"></div>
    </div>
    """
  end
end
