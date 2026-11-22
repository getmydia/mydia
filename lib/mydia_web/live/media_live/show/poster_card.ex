defmodule MydiaWeb.MediaLive.Show.PosterCard do
  @moduledoc """
  The poster on the media detail page, with the edit button that opens the
  poster picker.
  """
  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Helpers, only: [get_poster_url: 1]

  attr :media_item, :map, required: true
  attr :can_update_media, :boolean, default: false

  def poster_card(assigns) do
    ~H"""
    <%!-- Poster - centered and smaller on mobile --%>
    <div class="card bg-base-100 shadow-xl mb-4 mx-auto w-48 sm:w-56 md:w-full relative group">
      <figure class="aspect-[2/3] bg-base-300 overflow-hidden rounded-box">
        <img
          src={get_poster_url(@media_item)}
          alt={@media_item.title}
          class="w-full h-full object-cover"
        />
      </figure>
      <%!-- Shown on hover and keyboard focus; always shown where there is no hover (touch). --%>
      <button
        :if={@can_update_media}
        id="poster-edit-button"
        type="button"
        phx-click="open_poster_picker"
        class="btn btn-circle btn-sm absolute top-2 right-2 opacity-0 group-hover:opacity-100 focus:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity"
        aria-label={gettext("Change poster")}
        title={gettext("Change poster")}
      >
        <.icon name="hero-pencil" class="w-4 h-4" />
      </button>
    </div>
    """
  end
end
