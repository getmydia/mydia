defmodule MydiaWeb.MediaLive.Show.FranchiseEventsTest do
  @moduledoc """
  Covers the guest request path for a missing franchise movie.

  The shared media rail renders a Request button for a guest on any unowned
  card, including a franchise card. Without a handler for the event it emits,
  the first click raises FunctionClauseError and takes the detail page down.
  """

  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Media.{Franchise, FranchiseEntry}
  alias MydiaWeb.MediaLive.Show.FranchiseEvents

  defp entry(attrs) do
    struct!(
      %FranchiseEntry{tmdb_id: 1, title: "Untitled", year: 2001, poster_path: "/p.jpg"},
      attrs
    )
  end

  defp socket(franchise, user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        franchise: franchise,
        current_user: user,
        flash: %{}
      }
    }
  end

  defp franchise(entries) do
    %Franchise{
      name: "Test Collection",
      entries: entries,
      owned_count: Enum.count(entries, & &1.in_library?),
      total_count: length(entries)
    }
  end

  test "records a request and marks the entry" do
    user = user_fixture(%{role: "guest"})

    franchise =
      franchise([
        entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
        entry(%{tmdb_id: 672, title: "Chamber of Secrets", year: 2002})
      ])

    {:noreply, updated} =
      FranchiseEvents.request_franchise_movie(%{"tmdb_id" => "672"}, socket(franchise, user))

    requested = Enum.find(updated.assigns.franchise.entries, &(&1.tmdb_id == 672))

    assert requested.request_status != nil
  end

  test "ignores an id that is not in the franchise" do
    user = user_fixture(%{role: "guest"})
    franchise = franchise([entry(%{tmdb_id: 671}), entry(%{tmdb_id: 672})])

    assert {:noreply, _socket} =
             FranchiseEvents.request_franchise_movie(
               %{"tmdb_id" => "999"},
               socket(franchise, user)
             )
  end

  test "ignores a malformed id" do
    user = user_fixture(%{role: "guest"})
    franchise = franchise([entry(%{tmdb_id: 671}), entry(%{tmdb_id: 672})])

    assert {:noreply, _socket} =
             FranchiseEvents.request_franchise_movie(
               %{"tmdb_id" => "not-a-number"},
               socket(franchise, user)
             )
  end

  test "ignores the event when no franchise is loaded" do
    user = user_fixture(%{role: "guest"})

    assert {:noreply, _socket} =
             FranchiseEvents.request_franchise_movie(%{"tmdb_id" => "672"}, socket(nil, user))
  end
end
