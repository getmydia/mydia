defmodule MydiaWeb.MediaLive.Show.EpisodeFetchEvents do
  @moduledoc false

  # The show page while a background episode fetch is pending: the notice
  # that replaces the empty episode list, and the reload once the fetch lands.

  use MydiaWeb, :html

  alias Mydia.Jobs.EpisodeFetch
  alias MydiaWeb.MediaLive.Show.Helpers
  alias MydiaWeb.MediaLive.Show.Loaders

  @doc """
  Assigns `:fetching_episodes?`: true for a TV show with no episodes yet and a
  pending `EpisodeFetch` job.
  """
  def assign_fetching(socket) do
    assign(socket, :fetching_episodes?, fetching?(socket.assigns.media_item))
  end

  @doc """
  Handles a `:event_created` broadcast: events for this item refresh the
  timeline, and the episodes arriving also reload the episode state.
  """
  def handle_event_created(event, socket) do
    media_item = socket.assigns.media_item

    if event.resource_type == "media_item" && event.resource_id == media_item.id do
      timeline_events = Loaders.load_timeline_events(media_item, socket.assigns.current_user)

      socket
      |> maybe_reload(event)
      |> assign(:timeline_events, timeline_events)
    else
      socket
    end
  end

  @doc """
  Reloads everything that depends on the episodes when the fetch announces
  `media_item.episodes_refreshed`; any other event is a no-op.
  """
  def maybe_reload(socket, %{type: "media_item.episodes_refreshed"}) do
    media_item =
      Loaders.load_media_item(socket.assigns.current_scope, socket.assigns.media_item.id)

    {next_episode, next_episode_state} = Loaders.load_next_episode(media_item, socket)

    socket
    |> assign(:media_item, media_item)
    |> assign(:fetching_episodes?, false)
    |> Loaders.assign_downloads(Loaders.load_downloads_with_status(media_item))
    |> assign(:next_episode, next_episode)
    |> assign(:next_episode_state, next_episode_state)
    |> assign(:expanded_seasons, Helpers.default_expanded_seasons(media_item, next_episode))
  end

  def maybe_reload(socket, _event), do: socket

  defp fetching?(%{type: "tv_show", episodes: []} = media_item),
    do: EpisodeFetch.pending?(media_item.id)

  defp fetching?(_media_item), do: false

  attr :media_item, :map, required: true
  attr :fetching_episodes?, :boolean, required: true

  def notice(assigns) do
    ~H"""
    <div
      :if={@media_item.type == "tv_show" && @fetching_episodes?}
      class="card bg-base-200 shadow-lg"
    >
      <div id="episodes-fetching" class="flex items-center gap-2 p-6 text-base-content/70">
        <span class="loading loading-spinner loading-sm"></span>{gettext("Fetching episodes...")}
      </div>
    </div>
    """
  end
end
