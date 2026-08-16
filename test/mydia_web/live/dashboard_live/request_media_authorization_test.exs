defmodule MydiaWeb.DashboardLive.RequestMediaAuthorizationTest do
  @moduledoc """
  Covers the request_media guard on the Dashboard trending rails.

  can_submit_request?/1 is true only for a guest, but nothing enforced that on
  this handler, so any authenticated user could push the event over the socket
  and create a request row even though trending_card_action/1 renders them no
  Request button. The guard has to sit in handle_event, before the
  send(self(), ...): a guard only on handle_info would still let the push set
  requesting_item_id and flip the UI into "Requesting...".
  """

  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.MediaRequests
  alias MydiaWeb.DashboardLive.Index

  defp stub_socket(current_user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        requesting_item_id: nil,
        current_user: current_user
      }
    }
  end

  test "a non-guest pushing request_media creates no MediaRequest row" do
    socket = stub_socket(user_fixture(%{role: "user"}))

    {:noreply, updated} =
      Index.handle_event(
        "request_media",
        %{"tmdb_id" => "693134", "media_type" => "movie"},
        socket
      )

    assert updated.assigns.requesting_item_id == nil
    refute_received {:request_media, _, _}
    assert MediaRequests.list_requests(status: "pending") == []
  end

  test "a guest pushing request_media is allowed through to handle_info" do
    socket = stub_socket(user_fixture(%{role: "guest"}))

    {:noreply, updated} =
      Index.handle_event(
        "request_media",
        %{"tmdb_id" => "693134", "media_type" => "movie"},
        socket
      )

    assert updated.assigns.requesting_item_id == "693134"
    assert_received {:request_media, "693134", :movie}
  end
end
