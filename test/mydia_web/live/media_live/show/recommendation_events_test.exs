defmodule MydiaWeb.MediaLive.Show.RecommendationEventsTest do
  @moduledoc false

  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.MediaRequests
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  defp result(attrs) do
    struct!(
      %SearchResult{provider_id: "1", provider: :metadata_relay, media_type: :movie},
      attrs
    )
  end

  defp stub_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      recommendations: [],
      adding_recommendation_tmdb_ids: MapSet.new(),
      requesting_recommendation_id: nil,
      current_user: user_fixture()
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      private: %{live_temp: %{}}
    }
  end

  describe "handle_load_result/2" do
    # Regression: RecommendationEvents.decorate/2 enriched with library status
    # but never with request status, though request_recommendation/2 does call
    # enrich_with_request_status/2 after a successful request. A guest who
    # requested a recommended title and reloaded the page would see an enabled
    # Request button again.
    #
    # The viewer here (the socket's current_user) is a guest: request_status
    # only ever affects the Request button, which only guests see, so the
    # enrichment now runs only for a viewer who can submit a request.
    test "stamps request_status from an outstanding request and leaves the rest nil" do
      requester = user_fixture(%{role: "guest"})

      current =
        media_item_fixture(%{
          type: "movie",
          title: "Current",
          tmdb_id: System.unique_integer([:positive])
        })

      requested_tmdb_id = System.unique_integer([:positive])
      untouched_tmdb_id = System.unique_integer([:positive])

      {:ok, _request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "Requested Rec",
          tmdb_id: requested_tmdb_id,
          requester_id: requester.id
        })

      results = [
        result(%{provider_id: to_string(requested_tmdb_id), title: "Requested Rec"}),
        result(%{provider_id: to_string(untouched_tmdb_id), title: "Untouched Rec"})
      ]

      socket = stub_socket(%{media_item: current, current_user: user_fixture(%{role: "guest"})})

      {:noreply, socket} = RecommendationEvents.handle_load_result({:ok, {:ok, results}}, socket)

      requested =
        Enum.find(
          socket.assigns.recommendations,
          &(&1.provider_id == to_string(requested_tmdb_id))
        )

      untouched =
        Enum.find(
          socket.assigns.recommendations,
          &(&1.provider_id == to_string(untouched_tmdb_id))
        )

      assert requested.request_status == "pending"
      assert untouched.request_status == nil
    end

    # Regression: request_status_map/0 issued two unfiltered list_requests/1
    # queries and PR #461 ran them on every recommendations load, though the
    # value only ever affects the Request button that only a guest sees. A
    # non-guest viewer must not pay for a query whose result they can never
    # act on.
    test "a non-guest viewer sees no request_status even for an outstanding request" do
      requester = user_fixture(%{role: "guest"})

      current =
        media_item_fixture(%{
          type: "movie",
          title: "Current",
          tmdb_id: System.unique_integer([:positive])
        })

      requested_tmdb_id = System.unique_integer([:positive])

      {:ok, _request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "Requested Rec",
          tmdb_id: requested_tmdb_id,
          requester_id: requester.id
        })

      results = [result(%{provider_id: to_string(requested_tmdb_id), title: "Requested Rec"})]

      socket = stub_socket(%{media_item: current, current_user: user_fixture(%{role: "user"})})

      {:noreply, socket} = RecommendationEvents.handle_load_result({:ok, {:ok, results}}, socket)

      requested =
        Enum.find(
          socket.assigns.recommendations,
          &(&1.provider_id == to_string(requested_tmdb_id))
        )

      assert Map.get(requested, :request_status) == nil
    end
  end

  describe "request_recommendation/2" do
    # Regression: can_submit_request?/1 returns true only for a guest, but
    # nothing enforced that on this handler, so any authenticated user could
    # push the event over the socket and create a request row even though the
    # UI renders them no button.
    test "a non-guest user creates no request and leaves recommendations untouched" do
      current =
        media_item_fixture(%{
          type: "movie",
          title: "Current",
          tmdb_id: System.unique_integer([:positive])
        })

      tmdb_id = System.unique_integer([:positive])
      recommendations = [result(%{provider_id: to_string(tmdb_id), title: "Blocked"})]

      socket =
        stub_socket(%{
          media_item: current,
          recommendations: recommendations,
          current_user: user_fixture(%{role: "user"})
        })

      {:noreply, updated} =
        RecommendationEvents.request_recommendation(%{"tmdb_id" => to_string(tmdb_id)}, socket)

      assert updated.assigns.recommendations == recommendations
      assert updated.assigns.requesting_recommendation_id == nil
      assert MediaRequests.list_requests(status: "pending") == []
    end
  end

  describe "with_in_flight/2" do
    # Regression for #459: the rail used to read a single
    # :adding_recommendation_id, which can only ever name one card. Clicking a
    # second Add overwrote it, so the first card lost its spinner while its add
    # was still running and read as unresponsive.
    test "flags every id in the set, not only the most recent" do
      items = [
        result(%{provider_id: "1"}),
        result(%{provider_id: "2"}),
        result(%{provider_id: "3"})
      ]

      [first, second, third] =
        RecommendationEvents.with_in_flight(items, MapSet.new([1, 2]))

      assert first.adding
      assert second.adding
      refute third.adding
    end

    test "flags nothing when no add is in flight" do
      items = [result(%{provider_id: "1"})]

      [only] = RecommendationEvents.with_in_flight(items, MapSet.new())

      refute only.adding
    end

    # A malformed provider_id must not raise here: safe_provider_id/1 returns nil
    # for one, and nil is simply not a member of the in-flight set.
    test "treats an unparseable provider_id as not in flight" do
      items = [result(%{provider_id: "not-a-number"})]

      [only] = RecommendationEvents.with_in_flight(items, MapSet.new([1]))

      refute only.adding
    end
  end
end
