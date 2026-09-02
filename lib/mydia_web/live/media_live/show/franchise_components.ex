defmodule MydiaWeb.MediaLive.Show.FranchiseComponents do
  @moduledoc """
  The franchise strip on a movie's detail page: every movie in the same TMDB
  collection, marked owned or missing.

  This is an adapter rather than a renderer. It maps `FranchiseEntry` structs
  onto the shape `DiscoverComponents.media_rail/1` expects and delegates, so a
  collection and a recommendations rail draw the same card.
  """
  use MydiaWeb, :html

  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DiscoverComponents

  @doc """
  Renders the franchise strip.

  The heading is the franchise's own name. TMDB already suffixes these with
  "Collection", so no generic label is added; that also keeps the section from
  reading as one of the user's own collections.
  """
  attr :franchise, :map, required: true
  attr :can_add, :boolean, required: true
  attr :adding_tmdb_ids, MapSet, required: true
  attr :current_user, :map, required: true
  attr :libraries, :list, default: []

  def franchise_section(assigns) do
    assigns = assign(assigns, :items, items(assigns.franchise))

    ~H"""
    <DiscoverComponents.media_rail
      id="franchise-section"
      title={@franchise.name}
      items={@items}
      media_type={:movie}
      current_user={@current_user}
      can_add={@can_add}
      adding_ids={@adding_tmdb_ids}
      libraries={@libraries}
      on_select={nil}
      add_event="add_franchise_movie"
      request_event="request_franchise_movie"
    >
      <:badge>
        <span class={[
          "badge badge-sm",
          if(@franchise.owned_count == @franchise.total_count,
            do: "badge-success",
            else: "badge-ghost"
          )
        ]}>
          {@franchise.owned_count} of {@franchise.total_count}
        </span>
      </:badge>
    </DiscoverComponents.media_rail>
    """
  end

  # A franchise entry is a TMDB collection member -- there is no TVDB
  # equivalent -- so it is built as a real %SearchResult{} with `provider:
  # :tmdb` rather than a bare map. `Ref.from_search_result/1`, which the shared
  # card calls to build its `phx-value-ref`, pattern-matches on the struct.
  defp items(franchise) do
    Enum.map(franchise.entries, fn entry ->
      %SearchResult{
        provider_id: to_string(entry.tmdb_id),
        provider: :tmdb,
        media_type: :movie,
        title: entry.title,
        year: entry.year,
        poster_path: entry.poster_path,
        vote_average: entry.vote_average
      }
      |> Map.merge(%{
        in_library: entry.in_library?,
        monitored: entry.monitored,
        id: entry.media_item_id,
        navigate: navigate_to(entry),
        current: entry.current?,
        request_status: entry.request_status
      })
    end)
  end

  # The current entry gets no navigate target. trending_card/1 checks navigate
  # before on_select, so setting it would turn this movie's poster into a link
  # back to the page the user is already on.
  defp navigate_to(%{current?: true}), do: nil
  defp navigate_to(%{media_item_id: nil}), do: nil
  defp navigate_to(%{media_item_id: id}), do: ~p"/media/#{id}"
end
