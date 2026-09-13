defmodule MydiaWeb.LibrarySchema.LookupTest do
  use MydiaWeb.ConnCase

  import Mydia.Factory
  import Ecto.Query

  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.LibraryApi.Principal
  alias Mydia.Repo

  @admin %Principal{role: "admin", source: :api_key}

  @lookup """
  query Lookup($query: String!, $type: MediaType!) {
    lookup(query: $query, type: $type) {
      provider
      providerId
      type
      title
      year
      posterUrl
      imdbId
      inLibrary { id title }
    }
  }
  """

  defp run(query, variables) do
    Absinthe.run(query, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  # The relay serves movie search at /tmdb/movies/search
  # (lib/mydia/metadata/provider/relay.ex:1275-1277: `search_endpoint(:movie)`),
  # not /tmdb/search/movie. Stubbing the wrong path leaves the request unstubbed,
  # which Bypass turns into a 404 rather than a test failure at the stub.
  defp stub_tmdb_movie_search(bypass, results) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => results}))
    end)
  end

  defp relay_config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 30_000}
    }
  end

  test "returns relay results mapped onto LookupResult" do
    bypass = Bypass.open()

    stub_tmdb_movie_search(bypass, [
      %{
        "id" => 603,
        "title" => "The Matrix",
        "release_date" => "1999-03-31",
        "poster_path" => "/matrix.jpg",
        "overview" => "A hacker learns the truth.",
        "imdb_id" => "tt0133093",
        "media_type" => "movie"
      }
    ])

    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, relay_config(bypass).base_url)
    on_exit(fn -> Application.put_env(:mydia, :metadata_relay_url, previous) end)

    assert {:ok, %{data: %{"lookup" => [result]}}} =
             run(@lookup, %{"query" => "Matrix", "type" => "MOVIE"})

    assert result["provider"] == "TMDB"
    assert result["providerId"] == "603"
    assert result["type"] == "MOVIE"
    assert result["title"] == "The Matrix"
    assert result["year"] == 1999
    assert result["posterUrl"] =~ "/matrix.jpg"
    assert result["imdbId"] == "tt0133093"
    assert result["inLibrary"] == nil
  end

  test "an in-library hit deleted between the item query and the marker read reports no inLibrary" do
    bypass = Bypass.open()

    stub_tmdb_movie_search(bypass, [
      %{
        "id" => 604,
        "title" => "In Library",
        "release_date" => "2001-01-01",
        "poster_path" => "/in-library.jpg",
        "overview" => "A hit that is already in the library.",
        "media_type" => "movie"
      }
    ])

    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, relay_config(bypass).base_url)
    on_exit(fn -> Application.put_env(:mydia, :metadata_relay_url, previous) end)

    movie = insert(:media_item, type: "movie", title: "In Library", tmdb_id: 604)

    # The hit was hydrated before a concurrent delete committed, so the item
    # still resolves while its marker is already a tombstone.
    Repo.update_all(
      from(r in MediaItemRevision, where: r.media_item_id == ^movie.id),
      set: [deleted: true]
    )

    assert {:ok, %{data: %{"lookup" => [result]}}} =
             run(@lookup, %{"query" => "In Library", "type" => "MOVIE"})

    assert result["inLibrary"] == nil
  end
end
