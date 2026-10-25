defmodule MydiaWeb.DashboardLive.EditHomeComponents do
  @moduledoc """
  Components for the Edit Home customization modal.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [modal: 1, icon: 1]

  alias Phoenix.LiveView.JS

  @doc "Renders the Edit Home modal dialog."
  attr :editing_home, :boolean, required: true
  attr :visible_widgets, :list, required: true
  attr :hidden_widgets, :list, required: true

  def edit_home_modal(assigns) do
    ~H"""
    <.modal id="edit-home-modal" show={@editing_home} on_cancel={JS.push("close_edit_home")}>
      <div class="space-y-6">
        <div>
          <h2 class="text-xl font-bold">{gettext("Customize Home")}</h2>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext(
              "Choose which sections appear on your dashboard. Drag the handle to reorder them."
            )}
          </p>
        </div>

        <div class="space-y-2">
          <div id="edit-home-visible" phx-hook="HomeWidgetSort" class="space-y-2">
            <div
              :for={widget <- @visible_widgets}
              id={"edit-home-widget-#{widget.key}"}
              data-key={widget.key}
              class="flex items-center p-3 rounded-lg bg-base-200/50 border border-base-content/10 gap-3"
            >
              <button
                id={"edit-home-handle-#{widget.key}"}
                type="button"
                data-drag-handle
                class="btn btn-ghost btn-xs btn-square shrink-0 cursor-grab active:cursor-grabbing touch-none"
                aria-label={
                  gettext("Reorder %{widget}. Use arrow keys to move.",
                    widget: widget_label(widget)
                  )
                }
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </button>
              <label class="flex items-center gap-3 cursor-pointer flex-1 min-w-0">
                <input
                  type="checkbox"
                  checked
                  phx-click="toggle_home_widget"
                  phx-value-key={widget.key}
                  class="checkbox checkbox-primary checkbox-sm"
                />
                <div class="min-w-0">
                  <p class="font-medium text-sm truncate">{widget_label(widget)}</p>
                  <p class="text-xs text-base-content/60 truncate">
                    {widget_description(widget)}
                  </p>
                </div>
              </label>
            </div>
          </div>

          <!-- Hidden divider -->
          <%= if @hidden_widgets != [] do %>
            <div class="divider text-xs text-base-content/50 uppercase my-4">
              {gettext("Hidden")}
            </div>

            <%= for widget <- @hidden_widgets do %>
              <div
                id={"edit-home-widget-#{widget.key}"}
                class="flex items-center justify-between p-3 rounded-lg bg-base-100 border border-dashed border-base-content/15 gap-3"
              >
                <label class="flex items-center gap-3 cursor-pointer flex-1 min-w-0">
                  <input
                    type="checkbox"
                    phx-click="toggle_home_widget"
                    phx-value-key={widget.key}
                    class="checkbox checkbox-primary checkbox-sm"
                  />
                  <div class="min-w-0">
                    <p class="font-medium text-sm text-base-content/70 truncate">
                      {widget_label(widget)}
                    </p>
                    <p class="text-xs text-base-content/50 truncate">
                      {widget_description(widget)}
                    </p>
                  </div>
                </label>
              </div>
            <% end %>
          <% end %>
        </div>

        <div class="flex items-center justify-between pt-4 border-t border-base-content/10">
          <button
            id="reset-home-widgets"
            type="button"
            phx-click="reset_home_widgets"
            class="btn btn-ghost btn-sm text-error"
          >
            {gettext("Reset to default")}
          </button>
          <button
            type="button"
            phx-click="close_edit_home"
            class="btn btn-primary btn-sm"
          >
            {gettext("Done")}
          </button>
        </div>
      </div>
    </.modal>
    """
  end

  # The widget catalog (`Mydia.Accounts.HomeLayout`) carries English text, so the
  # web side translates by key. An unknown key falls back to the catalog text.
  defp widget_label(%{key: :library_stats}), do: gettext("Library stats")
  defp widget_label(%{key: :system_health}), do: gettext("System health")
  defp widget_label(%{key: :quick_actions}), do: gettext("Quick actions")
  defp widget_label(%{key: :recently_added}), do: gettext("Recently added")
  defp widget_label(%{key: :shelves}), do: gettext("Picked for you")
  defp widget_label(%{key: :recently_added_movies}), do: gettext("Recently added movies")
  defp widget_label(%{key: :recently_added_tv}), do: gettext("Recently added TV shows")
  defp widget_label(%{key: :trending_movies}), do: gettext("Trending movies")
  defp widget_label(%{key: :trending_tv}), do: gettext("Trending TV shows")
  defp widget_label(%{key: :regional}), do: gettext("In your country")
  defp widget_label(%{key: :episodes}), do: gettext("Your activity")
  defp widget_label(widget), do: widget.label

  defp widget_description(%{key: :library_stats}),
    do: gettext("Movies, TV shows, downloads, and storage counters")

  defp widget_description(%{key: :system_health}),
    do: gettext("Health status for clients, indexers, media servers, duplicates, and trash")

  defp widget_description(%{key: :quick_actions}),
    do: gettext("Shortcuts to add, import, or request media")

  defp widget_description(%{key: :recently_added}),
    do: gettext("Recently added movies and TV shows")

  defp widget_description(%{key: :shelves}),
    do: gettext("Suggestions from your plugins, such as the Assistant")

  defp widget_description(%{key: :recently_added_movies}),
    do: gettext("Recently added movies only")

  defp widget_description(%{key: :recently_added_tv}),
    do: gettext("Recently added TV shows only")

  defp widget_description(%{key: :trending_movies}), do: gettext("Trending movies rail")
  defp widget_description(%{key: :trending_tv}), do: gettext("Trending TV shows rail")

  defp widget_description(%{key: :regional}),
    do: gettext("What's in cinemas and on your streaming services")

  defp widget_description(%{key: :episodes}),
    do: gettext("Recently aired and coming soon episodes")

  defp widget_description(widget), do: widget.description
end
