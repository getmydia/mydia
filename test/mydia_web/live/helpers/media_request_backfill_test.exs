defmodule MydiaWeb.Live.Helpers.MediaRequestBackfillTest do
  @moduledoc """
  Requests created before the poster_path column existed fill in on first view.
  A failed fetch must leave the row alone so the card falls back to the
  placeholder and the next visit retries.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry, and
  # a shared sandbox is what lets the backfill's Tasks reach the Repo.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataStub

  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests
  alias Mydia.MetadataStubProvider
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  setup :setup_metadata_stub

  setup do
    %{user: user_fixture(%{role: "guest"})}
  end

  describe "needs_poster?/1" do
    test "true only for a resolvable request with no poster yet" do
      assert MediaRequestHelpers.needs_poster?(%MediaRequest{tmdb_id: 550, poster_path: nil})
      refute MediaRequestHelpers.needs_poster?(%MediaRequest{tmdb_id: 550, poster_path: "/p.jpg"})
      refute MediaRequestHelpers.needs_poster?(%MediaRequest{imdb_id: "tt1", poster_path: nil})
    end
  end

  describe "backfill_poster_paths/1" do
    test "fills a movie request from its tmdb_id", %{user: user} do
      request = request_fixture(user, %{tmdb_id: MetadataStubProvider.movie_tmdb_id()})

      assert :ok = MediaRequestHelpers.backfill_poster_paths([request])
      assert reload(request).poster_path == "/stub-movie-poster.jpg"
    end

    test "fills a series request that only has a tvdb_id", %{user: user} do
      request =
        request_fixture(user, %{
          media_type: "tv_show",
          title: "Stub Series",
          tvdb_id: MetadataStubProvider.series_tvdb_id()
        })

      assert :ok = MediaRequestHelpers.backfill_poster_paths([request])
      assert reload(request).poster_path == "/stub-series-poster.jpg"
    end

    test "leaves an imdb-only request untouched", %{user: user} do
      request = request_fixture(user, %{tmdb_id: nil, imdb_id: "tt0137523"})

      assert :ok = MediaRequestHelpers.backfill_poster_paths([request])
      assert is_nil(reload(request).poster_path)
    end

    test "leaves the row alone when the provider fails", %{user: user} do
      request = request_fixture(user, %{tmdb_id: MetadataStubProvider.missing_id()})

      assert :ok = MediaRequestHelpers.backfill_poster_paths([request])
      assert is_nil(reload(request).poster_path)
    end

    test "does not overwrite a poster that is already set", %{user: user} do
      request = request_fixture(user, %{tmdb_id: MetadataStubProvider.movie_tmdb_id()})
      {:ok, request} = MediaRequests.update_poster_path(request, "/keep.jpg")

      assert :ok = MediaRequestHelpers.backfill_poster_paths([request])
      assert reload(request).poster_path == "/keep.jpg"
    end
  end

  defp request_fixture(user, attrs) do
    base = %{
      media_type: "movie",
      title: "Stub Movie",
      year: 1999,
      tmdb_id: MetadataStubProvider.movie_tmdb_id(),
      requester_id: user.id
    }

    {:ok, request} = MediaRequests.create_request(Map.merge(base, attrs))
    request
  end

  defp reload(request), do: Repo.get!(MediaRequest, request.id)
end
