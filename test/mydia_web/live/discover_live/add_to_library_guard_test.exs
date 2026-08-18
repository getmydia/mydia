defmodule MydiaWeb.DiscoverLive.AddToLibraryGuardTest do
  @moduledoc """
  Covers the in-flight guard on add_to_library.

  An impatient double-click sends the add_to_library event twice before the
  first handle_info runs. Without a guard the second event re-enters the
  success branch, sends a second :add_media_to_library message, and the
  duplicate add resolves to :already_in_library, flashing a false failure for
  a title the user only meant to add once. A connected LiveView test cannot
  reproduce this: render_click is a synchronous round trip, so the first
  click's handle_info completes before a second render_click is delivered.
  Calling handle_event/3 directly, the way request_media_authorization_test.exs
  does, is the seam that actually exercises the guard.
  """

  use Mydia.DataCase, async: false

  alias MydiaWeb.DiscoverLive.Index

  defp stub_socket(adding_item_ids) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        adding_item_ids: adding_item_ids
      }
    }
  end

  test "a repeat add_to_library for an id already in flight is dropped" do
    socket = stub_socket(MapSet.new(["693134"]))

    {:noreply, updated} =
      Index.handle_event(
        "add_to_library",
        %{"tmdb_id" => "693134", "media_type" => "movie"},
        socket
      )

    assert updated.assigns.adding_item_ids == MapSet.new(["693134"])
    refute_received {:add_media_to_library, _, _, _}
  end

  test "the first add_to_library for an id marks it in flight and dispatches the add" do
    socket = stub_socket(MapSet.new())

    {:noreply, updated} =
      Index.handle_event(
        "add_to_library",
        %{"tmdb_id" => "693134", "media_type" => "movie"},
        socket
      )

    assert updated.assigns.adding_item_ids == MapSet.new(["693134"])
    assert_received {:add_media_to_library, "693134", :movie, nil}
  end
end
