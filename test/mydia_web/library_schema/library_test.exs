defmodule MydiaWeb.LibrarySchema.LibraryTest do
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.LibraryApi.Principal
  alias Mydia.Media
  alias Mydia.Repo

  @admin %Principal{role: "admin", source: :api_key}

  @media_item """
  query Item($id: ID, $type: MediaType, $tmdbId: Int, $tvdbId: Int, $imdbId: String, $season: Int) {
    mediaItem(id: $id, type: $type, tmdbId: $tmdbId, tvdbId: $tvdbId, imdbId: $imdbId) {
      id
      type
      title
      year
      monitored
      addedAt
      updatedAt
      status { state monitored fileCount }
      episodes(season: $season) { seasonNumber episodeNumber hasFile monitored }
      qualityProfile { id name }
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

  test "mediaItem's updatedAt is the aggregate revision timestamp and advances on a child change" do
    show = insert(:tv_show, title: "Severance")
    episode = insert(:episode, media_item: show, monitored: true)

    assert {:ok, %{data: %{"mediaItem" => before_item}}} = run(@media_item, %{"id" => show.id})

    marker = Repo.get_by!(MediaItemRevision, media_item_id: show.id)
    assert before_item["updatedAt"] == DateTime.to_iso8601(marker.changed_at)

    {:ok, _} = Media.update_episode(episode, %{monitored: false})

    assert {:ok, %{data: %{"mediaItem" => item}}} = run(@media_item, %{"id" => show.id})

    assert item["updatedAt"] ==
             DateTime.to_iso8601(
               Repo.get_by!(MediaItemRevision, media_item_id: show.id).changed_at
             )

    assert item["updatedAt"] > before_item["updatedAt"]
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

  test "mediaItem rejects more than one identifier" do
    assert {:ok, %{errors: errors}} =
             run(@media_item, %{"id" => Ecto.UUID.generate(), "tmdbId" => 603})

    assert Enum.any?(errors, &(&1.extensions[:code] == "INVALID_INPUT"))
  end
end
