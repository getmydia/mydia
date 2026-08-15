defmodule MydiaWeb.DashboardLive.Components do
  @moduledoc """
  Dashboard-only function components.

  The recently-added rail is deliberately separate from
  `MydiaWeb.DiscoverComponents.media_rail/1`. That component is built around
  `trending_card/1`, whose vocabulary is "add to library" and "request media",
  and feeding it owned library content would mean passing dead event props and
  would make any future `trending_card` change a dashboard regression.
  """

  use Phoenix.Component
  use MydiaWeb, :verified_routes

  alias MydiaWeb.Live.Helpers.MediaImages

  @doc """
  A horizontally scrolling rail of recently added titles.

  Takes `Mydia.Media.RecentlyAdded.Entry` structs. Renders nothing at all when
  the list is empty, so a fresh install sees no empty placeholder.
  """
  attr :entries, :list, required: true
  attr :id, :string, default: "recently-added-rail"
  attr :title, :string, default: "Recently Added"

  def recently_added_rail(assigns) do
    ~H"""
    <div :if={@entries != []} id={@id} class="mb-6 md:mb-8">
      <div class="flex items-center gap-3 mb-3">
        <h2 class="text-2xl font-bold truncate">{@title}</h2>
      </div>

      <div class="flex gap-3 overflow-x-auto snap-x scroll-smooth pb-2">
        <div
          :for={{entry, index} <- Enum.with_index(@entries)}
          id={"#{@id}-item-#{entry.media_item.id}"}
          class="snap-start flex-shrink-0 w-36"
        >
          <div class="card bg-base-100 shadow-lg hover:shadow-xl transition-shadow duration-200 overflow-hidden">
            <.link navigate={~p"/media/#{entry.media_item.id}"}>
              <figure class="relative aspect-[2/3] overflow-hidden bg-base-300">
                <img
                  src={MediaImages.poster_url(entry.media_item)}
                  alt={entry.media_item.title}
                  class="w-full h-full object-cover"
                  loading={if index < 6, do: nil, else: "lazy"}
                />
                <span
                  :if={new_episode_label(entry)}
                  class="absolute bottom-1 left-1 right-1 badge badge-primary badge-sm justify-center truncate"
                >
                  {new_episode_label(entry)}
                </span>
              </figure>
            </.link>
            <div class="card-body p-3">
              <h3 class="card-title text-sm line-clamp-2" title={entry.media_item.title}>
                {entry.media_item.title}
              </h3>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Only shows carry a count. A movie's arrival is the card itself, so a badge
  # would say nothing the poster does not already say.
  defp new_episode_label(%{media_item: %{type: "tv_show"}, new_episode_count: 1}),
    do: "1 new episode"

  defp new_episode_label(%{media_item: %{type: "tv_show"}, new_episode_count: count})
       when is_integer(count) and count > 1 do
    "#{count} new episodes"
  end

  defp new_episode_label(_entry), do: nil
end
