defmodule MydiaWeb.LibrarySchema.LibraryTest do
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Principal

  @admin %Principal{role: "admin", source: :api_key}

  @media_item """
  query Item($id: ID, $type: MediaType, $tmdbId: Int, $tvdbId: Int, $imdbId: String, $season: Int) {
    mediaItem(id: $id, type: $type, tmdbId: $tmdbId, tvdbId: $tvdbId, imdbId: $imdbId) {
      id
      type
      title
      year
      monitored
      status { state monitored fileCount }
      episodes(season: $season) { seasonNumber episodeNumber hasFile monitored }
      qualityProfile { id name }
    }
  }
  """

  @media_items """
  query Items($first: Int, $after: String) {
    mediaItems(first: $first, after: $after) {
      edges { node { id title } cursor }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  defp run(query, variables) do
    Absinthe.run(query, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  test "mediaItem returns a movie with its real availability status" do
    movie = insert(:media_item, type: "movie", title: "Arrival", year: 2016)

    assert {:ok, %{data: %{"mediaItem" => item}}} = run(@media_item, %{"id" => movie.id})
    assert item["id"] == movie.id
    assert item["type"] == "MOVIE"
    assert item["title"] == "Arrival"
    assert item["year"] == 2016
    assert item["status"]["state"] == "MISSING"
    assert item["status"]["fileCount"] == 0
    assert item["episodes"] == []
  end

  test "a movie with a file reads as DOWNLOADED and counts it" do
    movie = insert(:media_item, type: "movie", title: "Arrival")
    insert(:media_file, media_item: movie, episode: nil)

    assert {:ok, %{data: %{"mediaItem" => %{"status" => status}}}} =
             run(@media_item, %{"id" => movie.id})

    assert status["state"] == "DOWNLOADED"
    assert status["fileCount"] == 1
  end

  test "a tv show's episodes report hasFile and are filtered by season" do
    show = insert(:tv_show, title: "Severance")
    episode = insert(:episode, media_item: show, season_number: 1, episode_number: 1)
    insert(:media_file, episode: episode, media_item: nil)
    insert(:episode, media_item: show, season_number: 2, episode_number: 1)

    assert {:ok, %{data: %{"mediaItem" => %{"episodes" => episodes}}}} =
             run(@media_item, %{"id" => show.id, "season" => 1})

    assert [
             %{
               "seasonNumber" => 1,
               "episodeNumber" => 1,
               "hasFile" => true,
               "monitored" => true
             }
           ] = episodes
  end

  test "mediaItem returns nil for an unknown id" do
    assert {:ok, %{data: %{"mediaItem" => nil}}} =
             run(@media_item, %{"id" => Ecto.UUID.generate()})
  end

  test "mediaItem rejects a malformed id" do
    assert {:ok, %{errors: errors}} = run(@media_item, %{"id" => "not-a-uuid"})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItem accepts each external identifier selector" do
    movie =
      insert(:media_item,
        type: "movie",
        title: "Arrival",
        tmdb_id: 329_865,
        imdb_id: "tt2543164"
      )

    show = insert(:tv_show, title: "Severance", tvdb_id: 371_980, tmdb_id: 95_396)

    # tmdbId requires a type: TMDB numbers movies and shows in separate namespaces.
    assert {:ok, %{data: %{"mediaItem" => %{"id" => id}}}} =
             run(@media_item, %{"tmdbId" => 329_865, "type" => "MOVIE"})

    assert id == movie.id

    assert {:ok, %{data: %{"mediaItem" => %{"id" => id}}}} =
             run(@media_item, %{"tmdbId" => 95_396, "type" => "TV_SHOW"})

    assert id == show.id

    assert {:ok, %{data: %{"mediaItem" => %{"id" => id}}}} =
             run(@media_item, %{"tvdbId" => 371_980, "type" => "TV_SHOW"})

    assert id == show.id

    # imdbId is unique across types on its own, so no type is needed.
    assert {:ok, %{data: %{"mediaItem" => %{"id" => id}}}} =
             run(@media_item, %{"imdbId" => "tt2543164"})

    assert id == movie.id
  end

  test "a tmdbId whose type disagrees with the stored row is not a match" do
    insert(:media_item, type: "movie", title: "Arrival", tmdb_id: 329_865)

    assert {:ok, %{data: %{"mediaItem" => nil}}} =
             run(@media_item, %{"tmdbId" => 329_865, "type" => "TV_SHOW"})
  end

  test "mediaItem requires type when tmdbId is the selector" do
    assert {:ok, %{errors: errors}} = run(@media_item, %{"tmdbId" => 329_865})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItems pages forward with a working cursor" do
    for n <- 1..3, do: insert(:media_item, type: "movie", title: "Movie #{n}")

    assert {:ok, %{data: %{"mediaItems" => %{"edges" => edges, "pageInfo" => page}}}} =
             run(@media_items, %{"first" => 2})

    assert length(edges) == 2
    assert page["hasNextPage"] == true
    assert is_binary(page["endCursor"])

    assert {:ok,
            %{
              data: %{
                "mediaItems" => %{"edges" => next_edges, "pageInfo" => next_page}
              }
            }} =
             run(@media_items, %{"first" => 2, "after" => page["endCursor"]})

    assert length(next_edges) == 1
    assert next_page["hasNextPage"] == false

    first_ids = Enum.map(edges, & &1["node"]["id"])
    next_ids = Enum.map(next_edges, & &1["node"]["id"])
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(next_ids))
  end

  test "an invalid cursor is an error rather than ignored" do
    assert {:ok, %{errors: errors}} = run(@media_items, %{"first" => 2, "after" => "garbage"})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItems rejects a cursor with a malformed boundary id" do
    cursor = Base.url_encode64("2026-09-11T00:00:00Z|not-a-uuid", padding: false)

    assert {:ok, %{errors: errors}} = run(@media_items, %{"first" => 2, "after" => cursor})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItems accepts an ISO-8601 updatedSince" do
    insert(:media_item, type: "movie", title: "Old", updated_at: ~U[2020-01-01 00:00:00Z])
    insert(:media_item, type: "movie", title: "New")

    query = """
    query($since: DateTime) {
      mediaItems(first: 50, updatedSince: $since) { edges { node { title } } }
    }
    """

    assert {:ok, %{data: %{"mediaItems" => %{"edges" => edges}}}} =
             run(query, %{"since" => "2021-01-01T00:00:00Z"})

    titles = Enum.map(edges, & &1["node"]["title"])
    assert "New" in titles
    refute "Old" in titles
  end

  test "mediaItems rejects a malformed updatedSince" do
    query = """
    query($since: DateTime) {
      mediaItems(first: 50, updatedSince: $since) { edges { node { id } } }
    }
    """

    # The DateTime scalar parses with DateTime.from_iso8601/1, so a non-date is a
    # document-level coercion error rather than a resolver-level one.
    assert {:ok, %{errors: errors}} = run(query, %{"since" => "yesterday"})
    assert errors != []
  end

  # `first` reaches Ecto's `limit`, where 0 and negative values do not mean "no
  # rows". Refusing them surfaces a client bug instead of returning something
  # surprising.
  test "mediaItems refuses first: 0" do
    assert {:ok, %{errors: errors}} = run(@media_items, %{"first" => 0})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItems refuses a negative first" do
    assert {:ok, %{errors: errors}} = run(@media_items, %{"first" => -5})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItems refuses a first above the cap" do
    assert {:ok, %{errors: errors}} = run(@media_items, %{"first" => 201})
    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end

  test "mediaItems accepts the cap itself" do
    insert(:media_item, type: "movie", title: "Only one")

    assert {:ok, %{data: %{"mediaItems" => %{"edges" => edges}}}} =
             run(@media_items, %{"first" => 200})

    assert length(edges) == 1
  end

  test "mediaItem rejects more than one identifier" do
    assert {:ok, %{errors: errors}} =
             run(@media_item, %{"id" => Ecto.UUID.generate(), "tmdbId" => 603})

    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end
end
