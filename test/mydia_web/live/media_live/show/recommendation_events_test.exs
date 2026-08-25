defmodule MydiaWeb.MediaLive.Show.RecommendationEventsTest do
  @moduledoc false

  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
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

    merged = Map.merge(defaults, assigns)
    merged = Map.put_new(merged, :current_scope, Scope.for_user(merged.current_user))

    %Phoenix.LiveView.Socket{
      assigns: merged,
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
        MediaRequests.create_request(Scope.unrestricted(), %{
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
        MediaRequests.create_request(Scope.unrestricted(), %{
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

  describe "handle_add_result/3" do
    # A completion must retire exactly its own id. The old code also derived a
    # single :adding_recommendation_id from whatever survived, via Enum.at(0),
    # which is how a still-running card lost its spinner (#459). This asserts
    # the set itself, which is now the only in-flight state there is.
    test "retires only the finished id and leaves the other in-flight adds" do
      socket =
        stub_socket(%{adding_recommendation_tmdb_ids: MapSet.new([11, 22, 33])})

      {:noreply, socket} =
        RecommendationEvents.handle_add_result(11, {:ok, {:error, :boom}}, socket)

      assert socket.assigns.adding_recommendation_tmdb_ids == MapSet.new([22, 33])
    end

    test "an exit retires its id like any other completion" do
      socket = stub_socket(%{adding_recommendation_tmdb_ids: MapSet.new([11, 22])})

      {:noreply, socket} =
        RecommendationEvents.handle_add_result(22, {:exit, :killed}, socket)

      assert socket.assigns.adding_recommendation_tmdb_ids == MapSet.new([11])
    end
  end
end
