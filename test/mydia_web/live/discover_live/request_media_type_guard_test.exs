defmodule MydiaWeb.DiscoverLive.RequestMediaTypeGuardTest do
  @moduledoc """
  Covers the media_type filter on the request_media item lookup.

  `handle_event("request_media", %{"ref" => raw_ref, "media_type" => ...},
  socket)` takes both `ref` and `media_type` from client params, and TMDB
  namespaces movie and TV ids independently (a movie and a show can share one
  numeric id). Before this filter, `handle_info({:request_media, ref,
  media_type}, socket)` resolved the item by the ref's bare id alone, so a
  forged event pairing one tab's id with the other type's media_type could
  match a real item of the wrong kind and hand it to
  `MediaRequestHelpers.handle_request_media/3` with a media_type that does
  not describe it -- storing its id under the wrong request media_type.
  """

  use Mydia.DataCase, async: false

  alias Mydia.MediaRequests
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DiscoverLive.Index

  test "a request_media whose media_type does not match the found item's own type is dropped" do
    movie_id = System.unique_integer([:positive])

    movie = %SearchResult{
      provider_id: to_string(movie_id),
      provider: :tmdb,
      media_type: :movie,
      title: "Harbor Static"
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        requesting_item_id: "placeholder",
        items: [movie],
        selected_recommendations: []
      }
    }

    # The grid is showing a movie, but the event claims tv_show for the same
    # numeric id -- exactly the shape a forged or stale client event takes.
    {:noreply, updated} =
      Index.handle_info({:request_media, {:tmdb, movie_id}, :tv_show}, socket)

    assert updated.assigns.requesting_item_id == nil
    assert MediaRequests.list_requests(status: "pending") == []
  end
end
