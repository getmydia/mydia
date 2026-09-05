defmodule MydiaWeb.Live.Helpers.MediaRequestHelpersTest do
  use Mydia.DataCase, async: true

  alias Mydia.{Accounts, MediaRequests}
  alias Mydia.Media.MediaRequest
  alias Mydia.Metadata.Structs.SearchResult
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

  # Real %SearchResult{}s, not bare maps: Ref.from_search_result/1
  # pattern-matches the struct on purpose, so a caller can never build one
  # without a real provider. item/2 is always exercised as a movie
  # (media_type: :movie is what every caller of handle_request_media/3 below
  # passes) and tvdb_item/2 always as a TVDB-sourced show, so :tmdb/:tvdb here
  # are not habit-defaults -- they are what each fixture actually represents.
  defp item(tmdb_id, title \\ "Card Movie") do
    %SearchResult{
      provider_id: to_string(tmdb_id),
      provider: :tmdb,
      media_type: :movie,
      title: title,
      year: 2024
    }
  end

  defp tvdb_item(tvdb_id, title \\ "Card Series") do
    %SearchResult{
      provider_id: to_string(tvdb_id),
      provider: :tvdb,
      media_type: :tv_show,
      title: title,
      year: 2024
    }
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
      assert map[{:movie, :tmdb, tmdb_id}] == "pending"
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
      assert map[{:tv_show, :tvdb, tvdb_id}] == "pending"
    end

    # There is no TVDB movie catalog, so a movie card tagged provider: :tvdb
    # is either a forged event (media_type and ref pulled from different
    # cards) or a genuine TV show reached by a mismatched media_type. Either
    # way, its numeric id is not a TMDB id: storing it under tmdb_id would
    # name a real, unrelated TMDB movie if the two ever collide, or a movie
    # that does not exist if they don't. Mirrors the
    # `{:movie, {:tvdb, _}} -> {:error, {:metadata, :tvdb_ref_for_movie}}`
    # guard in `Mydia.Media.Add.resolve_attrs/4`.
    test "rejects a movie card tagged provider: :tvdb instead of storing it as tmdb_id" do
      user = guest()
      tvdb_id = System.unique_integer([:positive])
      mistagged_item = Map.put(item(tvdb_id), :provider, :tvdb)

      assert {:error, {:metadata, :tvdb_ref_for_movie}} =
               MediaRequestHelpers.handle_request_media(mistagged_item, :movie, user.id)

      refute MediaRequests.list_requests(status: "pending")
             |> Enum.any?(&(&1.tmdb_id == tvdb_id))
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
      assert MediaRequestHelpers.request_status_map()[{:movie, :tmdb, tmdb_id}] == "pending"
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

      assert MediaRequestHelpers.request_status_map()[{:tv_show, :tvdb, tvdb_id}] == "pending"
    end
  end

  describe "enrich_with_request_status/2" do
    test "stamps the status onto matching items and nil onto the rest" do
      requested = System.unique_integer([:positive])
      untouched = System.unique_integer([:positive])
      map = %{{:movie, :tmdb, requested} => "pending"}

      [a, b] =
        MediaRequestHelpers.enrich_with_request_status(
          [item(requested), item(untouched)],
          map
        )

      assert a.request_status == "pending"
      assert b.request_status == nil
    end

    test "does not let a TVDB show read as requested off a same-numbered TMDB movie's entry" do
      shared_id = System.unique_integer([:positive])

      movie =
        item(shared_id, "Shared Id Movie")
        |> Map.put(:media_type, :movie)

      series =
        tvdb_item(shared_id, "Shared Id Series")
        |> Map.put(:media_type, :tv_show)

      # Only the TMDB movie has an outstanding request, keyed with canonical
      # 3-tuple as request_status_map/0 stores it.
      map = %{{:movie, :tmdb, shared_id} => "pending"}

      [enriched_movie, enriched_series] =
        MediaRequestHelpers.enrich_with_request_status([movie, series], map)

      assert enriched_movie.request_status == "pending"
      assert is_nil(enriched_series.request_status)
    end

    test "reads a TVDB show's own request off its tagged key, unaffected by a same-numbered TMDB entry" do
      shared_id = System.unique_integer([:positive])

      movie =
        item(shared_id, "Other Shared Id Movie")
        |> Map.put(:media_type, :movie)

      series =
        tvdb_item(shared_id, "Other Shared Id Series")
        |> Map.put(:media_type, :tv_show)

      # No TMDB movie request exists; only the TVDB show does, keyed with canonical
      # 3-tuple as request_status_map/0 stores it.
      map = %{{:tv_show, :tvdb, shared_id} => "pending"}

      [enriched_movie, enriched_series] =
        MediaRequestHelpers.enrich_with_request_status([movie, series], map)

      assert is_nil(enriched_movie.request_status)
      assert enriched_series.request_status == "pending"
    end

    test "differentiates TMDB TV show from TMDB movie with identical numeric id" do
      user = guest()
      shared_id = System.unique_integer([:positive])

      {:ok, _req} =
        MediaRequests.create_request(%{
          media_type: "tv_show",
          title: "Shared Show",
          tmdb_id: shared_id,
          requester_id: user.id
        })

      map = MediaRequestHelpers.request_status_map()
      assert map[{:tv_show, :tmdb, shared_id}] == "pending"
      assert is_nil(map[{:movie, :tmdb, shared_id}])

      movie = item(shared_id, "Shared Movie") |> Map.put(:media_type, :movie)
      series = item(shared_id, "Shared Series") |> Map.put(:media_type, :tv_show)

      [enriched_movie, enriched_series] =
        MediaRequestHelpers.enrich_with_request_status([movie, series], map)

      assert is_nil(enriched_movie.request_status)
      assert enriched_series.request_status == "pending"
    end
  end
end
