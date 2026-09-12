defmodule Mydia.MediaRequests.PosterPathTest do
  use Mydia.DataCase

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests

  describe "poster_path column" do
    test "create_changeset casts poster_path" do
      changeset =
        MediaRequest.create_changeset(%MediaRequest{}, %{
          media_type: "movie",
          title: "Stub Movie",
          tmdb_id: 550,
          poster_path: "/stub-movie-poster.jpg",
          requester_id: Ecto.UUID.generate()
        })

      assert Ecto.Changeset.get_change(changeset, :poster_path) == "/stub-movie-poster.jpg"
    end

    test "update_poster_path/2 persists the path" do
      request = pending_request_fixture()

      assert {:ok, updated} = MediaRequests.update_poster_path(request, "/later.jpg")
      assert updated.poster_path == "/later.jpg"
      assert Repo.get!(MediaRequest, request.id).poster_path == "/later.jpg"
    end
  end

  describe "external_ref/1" do
    test "prefers tmdb_id when both ids are present" do
      assert MediaRequest.external_ref(%MediaRequest{tmdb_id: 550, tvdb_id: 81_189}) ==
               {:tmdb, 550}
    end

    test "falls back to tvdb_id" do
      assert MediaRequest.external_ref(%MediaRequest{tvdb_id: 81_189}) == {:tvdb, 81_189}
    end

    test "returns nil for an imdb-only request" do
      request = %MediaRequest{imdb_id: "tt0137523"}

      assert MediaRequest.external_ref(request) == nil
      refute MediaRequest.detailable?(request)
    end

    test "detailable? is true whenever an external ref exists" do
      assert MediaRequest.detailable?(%MediaRequest{tmdb_id: 550})
      assert MediaRequest.detailable?(%MediaRequest{tvdb_id: 81_189})
    end
  end

  describe "media_type_atom/1" do
    test "maps the stored string to an atom" do
      assert MediaRequest.media_type_atom(%MediaRequest{media_type: "tv_show"}) == :tv_show
      assert MediaRequest.media_type_atom(%MediaRequest{media_type: "movie"}) == :movie
    end
  end

  defp pending_request_fixture do
    user = user_fixture(%{role: "guest"})

    {:ok, request} =
      MediaRequests.create_request(Scope.unrestricted(), %{
        media_type: "movie",
        title: "Stub Movie",
        year: 1999,
        tmdb_id: 550,
        requester_id: user.id
      })

    request
  end
end
