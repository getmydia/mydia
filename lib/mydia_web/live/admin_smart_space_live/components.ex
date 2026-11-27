defmodule MydiaWeb.AdminSmartSpaceLive.Components do
  @moduledoc """
  Tab bodies for the Smart Space page. The streams are passed in as attrs, so
  the stream containers keep their ids and `phx-update="stream"`.
  """
  use MydiaWeb, :html

  alias MydiaWeb.AdminSmartSpaceLive.Index

  attr :rows, :any, required: true, doc: "the :upcoming stream"
  attr :count, :integer, required: true
  attr :enabled?, :boolean, required: true

  def upcoming_tab(assigns) do
    ~H"""
    <div>
      <div
        :if={@count == 0}
        id="smart-space-empty"
        class="alert alert-soft"
      >
        <.icon name="hero-sparkles" class="w-5 h-5" />
        <div>
          <%= if @enabled? do %>
            {gettext("Nothing is due in the next 30 days.")}
          <% else %>
            {gettext("Smart Space is off.")}
            <.link id="smart-space-settings-link" navigate={~p"/admin/settings"} class="link">
              {gettext("Turn it on in Settings")}
            </.link>
          <% end %>
        </div>
      </div>

      <div class="sm:overflow-x-auto" hidden={@count == 0}>
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Show")}</th>
              <th>{gettext("Unit")}</th>
              <th>{gettext("Size")}</th>
              <th>{gettext("Due")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="smart-space-upcoming" phx-update="stream">
            <tr :for={{dom_id, row} <- @rows} id={dom_id}>
              <td class="font-medium">{row.cleanup.title}</td>
              <td>{row.label}</td>
              <td>{Index.size(row.cleanup.bytes)}</td>
              <td>{row.due}</td>
              <td class="text-right">
                <button
                  id={"keep-#{dom_id}"}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="keep"
                  phx-value-media-item-id={row.cleanup.media_item_id}
                  phx-value-season-number={row.cleanup.season_number}
                  phx-value-episode-id={row.episode_id}
                  phx-value-unit={row.cleanup.unit}
                >
                  <.icon name="hero-bookmark" class="w-4 h-4" /> {gettext("Keep")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :keeps, :any, required: true, doc: "the :keeps stream"
  attr :count, :integer, required: true

  def kept_tab(assigns) do
    ~H"""
    <div>
      <div :if={@count == 0} id="smart-space-keeps-empty" class="alert alert-soft">
        {gettext("Nothing is kept. Keep a season from the Upcoming tab to exempt it.")}
      </div>

      <div class="sm:overflow-x-auto" hidden={@count == 0}>
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Show")}</th>
              <th>{gettext("Kept")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="smart-space-keeps" phx-update="stream">
            <tr :for={{dom_id, keep} <- @keeps} id={dom_id}>
              <td class="font-medium">{keep.media_item.title}</td>
              <td>{Index.keep_label(keep)}</td>
              <td class="text-right">
                <button
                  id={"unkeep-#{keep.id}"}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="unkeep"
                  phx-value-id={keep.id}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Remove")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
