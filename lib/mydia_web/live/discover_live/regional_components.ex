defmodule MydiaWeb.DiscoverLive.RegionalComponents do
  @moduledoc "The Discover country tab: landing rows and the country settings modal."
  use MydiaWeb, :html

  import MydiaWeb.DiscoverComponents
  import MydiaWeb.PosterCardComponents

  alias Mydia.Metadata.Countries
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
      <div :if={not @has_services} id="discover-services-prompt" class="card bg-base-200 mb-6">
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
            phx-click="open_country_settings"
          >
            Pick services
          </button>
        </div>
      </div>
      <%= for source <- @sources do %>
        <% param = RegionalSources.to_param(source) %>
        <% row = Map.get(@rows, param, %{status: :loading, items: []}) %>
        <% items = if @hide_owned, do: Enum.reject(row.items, & &1.in_library), else: row.items %>
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

  attr :settings, :map, required: true
  attr :countries, :list, required: true
  attr :saved_country, :string, default: nil

  def country_settings(assigns) do
    ~H"""
    <div
      id="discover-country-settings"
      class="modal modal-open"
      role="dialog"
      phx-window-keydown="close_country_settings"
      phx-key="Escape"
    >
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg">Your country</h3>
        <p class="text-sm text-base-content/60 mt-1">
          See what is in cinemas and on your streaming services where you live.
        </p>
        <form
          id="discover-country-settings-form"
          phx-change="country_settings_changed"
          phx-submit="save_country_settings"
          class="mt-4 space-y-4"
        >
          <label class="fieldset">
            <span class="fieldset-legend">Country</span>
            <select name="country" class="select select-bordered w-full" aria-label="Country">
              <option value="" selected={is_nil(@settings.country)}>Pick a country</option>
              <option
                :for={{code, name} <- @countries}
                value={code}
                selected={@settings.country == code}
              >
                {Countries.flag(code)} {name}
              </option>
            </select>
          </label>

          <div :if={@settings.country} id="discover-country-settings-services">
            <span class="fieldset-legend">Streaming services</span>
            <%= case @settings.status do %>
              <% :error -> %>
                <div class="alert alert-warning">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <span>Could not load the services for this country.</span>
                  <button
                    id="discover-country-settings-retry"
                    type="button"
                    class="btn btn-sm"
                    phx-click="retry_country_settings"
                  >
                    Retry
                  </button>
                </div>
              <% :ok -> %>
                <div class="filter flex flex-wrap gap-2 max-h-64 overflow-y-auto p-1">
                  <input
                    :for={provider <- @settings.providers}
                    type="checkbox"
                    name="services[]"
                    value={provider.id}
                    class="btn btn-sm"
                    aria-label={provider.name}
                    checked={MapSet.member?(@settings.selected_ids, provider.id)}
                  />
                </div>
              <% _loading -> %>
                <div class="flex justify-center py-6">
                  <span class="loading loading-spinner loading-md text-primary"></span>
                </div>
            <% end %>
          </div>

          <div class="modal-action items-center">
            <button
              :if={@saved_country}
              id="discover-country-settings-remove"
              type="button"
              class="btn btn-ghost text-error mr-auto"
              phx-click="remove_home_country"
            >
              Remove
            </button>
            <button
              id="discover-country-settings-cancel"
              type="button"
              class="btn btn-ghost"
              phx-click="close_country_settings"
            >
              Cancel
            </button>
            <button
              id="discover-country-settings-save"
              type="submit"
              class="btn btn-primary"
              disabled={is_nil(@settings.country)}
            >
              Save
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_country_settings"></div>
    </div>
    """
  end
end
