defmodule MydiaWeb.Live.Helpers.MediaRequestHelpersTest do
  use Mydia.DataCase

  import Mydia.AccountsFixtures

  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  describe "handle_request_media/3" do
    test "stores the card's poster path on the request" do
      user = user_fixture(%{role: "guest"})

      item = %{
        provider_id: "550",
        title: "Stub Movie",
        year: 1999,
        poster_path: "/stub-movie-poster.jpg"
      }

      assert {:ok, request, _statuses} =
               MediaRequestHelpers.handle_request_media(item, :movie, user.id)

      assert request.poster_path == "/stub-movie-poster.jpg"
      assert request.tmdb_id == 550
    end

    test "leaves poster_path nil when the card has no poster" do
      user = user_fixture(%{role: "guest"})

      item = %{provider_id: "550", title: "Stub Movie", year: 1999, poster_path: nil}

      assert {:ok, request, _statuses} =
               MediaRequestHelpers.handle_request_media(item, :movie, user.id)

      assert is_nil(request.poster_path)
    end
  end
end
