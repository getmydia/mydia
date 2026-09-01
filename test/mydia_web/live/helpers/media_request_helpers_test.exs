defmodule MydiaWeb.Live.Helpers.MediaRequestHelpersTest do
  use Mydia.DataCase, async: true

  alias Mydia.{Accounts, MediaRequests}
  alias Mydia.Media.MediaRequest
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  defp guest do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        username: "guest#{id}",
        email: "guest#{id}@example.com",
        password: "passwordpassword",
        role: "guest"
      })

    user
  end

  defp item(tmdb_id, title \\ "Card Movie") do
    %{provider_id: to_string(tmdb_id), title: title, year: 2024}
  end

  defp tvdb_item(tvdb_id, title \\ "Card Series") do
    %{provider_id: to_string(tvdb_id), title: title, year: 2024, provider: :tvdb}
  end

  describe "handle_request_media/3" do
    test "creates a pending request and returns it in the updated map" do
      user = guest()
      tmdb_id = System.unique_integer([:positive])

      assert {:ok, request, map} =
               MediaRequestHelpers.handle_request_media(item(tmdb_id), :movie, user.id)

      assert request.tmdb_id == tmdb_id
      assert request.status == "pending"
      assert request.requester_id == user.id
      assert map[tmdb_id] == "pending"
    end

    test "reports a duplicate when a pending request already exists" do
      user = guest()
      tmdb_id = System.unique_integer([:positive])

      assert {:ok, _request, _map} =
               MediaRequestHelpers.handle_request_media(item(tmdb_id), :movie, user.id)

      assert {:error, :duplicate_request} =
               MediaRequestHelpers.handle_request_media(item(tmdb_id), :movie, user.id)
    end

    test "stores the card's poster path on the request" do
      user = guest()
      tmdb_id = System.unique_integer([:positive])
      poster_item = Map.put(item(tmdb_id), :poster_path, "/stub-movie-poster.jpg")

      assert {:ok, request, _map} =
               MediaRequestHelpers.handle_request_media(poster_item, :movie, user.id)

      assert request.poster_path == "/stub-movie-poster.jpg"
    end

    test "leaves poster_path nil when the card has no poster" do
      user = guest()
      tmdb_id = System.unique_integer([:positive])

      assert {:ok, request, _map} =
               MediaRequestHelpers.handle_request_media(item(tmdb_id), :movie, user.id)

      assert is_nil(request.poster_path)
    end

    test "stores a TVDB-sourced TV show request under tvdb_id, not tmdb_id" do
      user = guest()
      tvdb_id = System.unique_integer([:positive])

      assert {:ok, request, map} =
               MediaRequestHelpers.handle_request_media(tvdb_item(tvdb_id), :tv_show, user.id)

      assert request.tvdb_id == tvdb_id
      assert is_nil(request.tmdb_id)
      assert MediaRequest.external_ref(request) == {:tvdb, tvdb_id}
      assert map[tvdb_id] == "pending"
    end

    test "still stores a movie under tmdb_id even when the card is tagged provider: :tvdb" do
      user = guest()
      tmdb_id = System.unique_integer([:positive])
      mistagged_item = Map.put(item(tmdb_id), :provider, :tvdb)

      assert {:ok, request, map} =
               MediaRequestHelpers.handle_request_media(mistagged_item, :movie, user.id)

      assert request.tmdb_id == tmdb_id
      assert is_nil(request.tvdb_id)
      assert map[tmdb_id] == "pending"
    end
  end

  describe "request_status_map/0" do
    test "includes pending requests from any requester" do
      first = guest()
      second = guest()
      tmdb_id = System.unique_integer([:positive])

      {:ok, _request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "Someone Else's Pick",
          tmdb_id: tmdb_id,
          requester_id: first.id
        })

      # The second guest must see it as already requested: create_request/1
      # rejects duplicates globally, so an enabled button would only error.
      assert MediaRequestHelpers.request_status_map()[tmdb_id] == "pending"
      assert second.id != first.id
    end

    test "includes a TVDB-sourced pending request" do
      guest_user = guest()
      tvdb_id = System.unique_integer([:positive])

      {:ok, _request} =
        MediaRequests.create_request(%{
          media_type: "tv_show",
          title: "Someone Else's Series",
          tvdb_id: tvdb_id,
          requester_id: guest_user.id
        })

      assert MediaRequestHelpers.request_status_map()[tvdb_id] == "pending"
    end
  end

  describe "enrich_with_request_status/2" do
    test "stamps the status onto matching items and nil onto the rest" do
      requested = System.unique_integer([:positive])
      untouched = System.unique_integer([:positive])
      map = %{requested => "pending"}

      [a, b] =
        MediaRequestHelpers.enrich_with_request_status(
          [item(requested), item(untouched)],
          map
        )

      assert a.request_status == "pending"
      assert b.request_status == nil
    end
  end
end
