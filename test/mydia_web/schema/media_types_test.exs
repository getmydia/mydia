defmodule MydiaWeb.Schema.MediaTypesTest do
  use MydiaWeb.ConnCase

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures

  @movie_query """
  query MovieDetail($id: ID!) {
    movie(id: $id) {
      id
      contentRating
    }
  }
  """

  @show_query """
  query ShowDetail($id: ID!) {
    tvShow(id: $id) {
      id
      contentRating
    }
  }
  """

  @movie_trailer_query """
  query MovieTrailer($id: ID!) {
    movie(id: $id) {
      id
      trailerUrl
    }
  }
  """

  @show_trailer_query """
  query ShowTrailer($id: ID!) {
    tvShow(id: $id) {
      id
      trailerUrl
    }
  }
  """

  @movie_cast_query """
  query MovieCast($id: ID!) {
    movie(id: $id) {
      id
      cast {
        name
        character
        profileUrl
      }
    }
  }
  """

  @show_cast_query """
  query ShowCast($id: ID!) {
    tvShow(id: $id) {
      id
      cast {
        name
        character
        profileUrl
      }
    }
  }
  """

  setup do
    %{user: AccountsFixtures.user_fixture()}
  end

  describe "movie.contentRating" do
    test "returns the persisted certification", ctx do
      movie =
        MediaFixtures.media_item_fixture(%{
          type: "movie",
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "The Matrix",
            "content_rating" => "R"
          }
        })

      assert {:ok, %{data: %{"movie" => %{"contentRating" => "R"}}}} =
               run_query(@movie_query, %{"id" => movie.id}, ctx.user)
    end

    test "is null when nothing was parsed", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})

      assert {:ok, %{data: %{"movie" => %{"contentRating" => nil}}}} =
               run_query(@movie_query, %{"id" => movie.id}, ctx.user)
    end
  end

  describe "tvShow.contentRating" do
    test "returns the persisted rating", ctx do
      show =
        MediaFixtures.media_item_fixture(%{
          type: "tv_show",
          metadata: %{
            "provider_id" => "1396",
            "provider" => "metadata_relay",
            "media_type" => "tv_show",
            "title" => "Breaking Bad",
            "content_rating" => "TV-MA"
          }
        })

      assert {:ok, %{data: %{"tvShow" => %{"contentRating" => "TV-MA"}}}} =
               run_query(@show_query, %{"id" => show.id}, ctx.user)
    end
  end

  describe "movie.trailerUrl" do
    test "returns the first persisted trailer's watch URL", ctx do
      movie =
        MediaFixtures.media_item_fixture(%{
          type: "movie",
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "The Matrix",
            "videos" => [
              %{"key" => "vKQi3bBA1y8", "site" => "YouTube", "type" => "Trailer"}
            ]
          }
        })

      assert {:ok, %{data: %{"movie" => %{"trailerUrl" => url}}}} =
               run_query(@movie_trailer_query, %{"id" => movie.id}, ctx.user)

      assert url == "https://www.youtube.com/watch?v=vKQi3bBA1y8"
    end

    test "is null when there are no videos", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})

      assert {:ok, %{data: %{"movie" => %{"trailerUrl" => nil}}}} =
               run_query(@movie_trailer_query, %{"id" => movie.id}, ctx.user)
    end
  end

  describe "tvShow.trailerUrl" do
    test "returns the first persisted trailer's watch URL", ctx do
      show =
        MediaFixtures.media_item_fixture(%{
          type: "tv_show",
          metadata: %{
            "provider_id" => "1396",
            "provider" => "metadata_relay",
            "media_type" => "tv_show",
            "title" => "Breaking Bad",
            "videos" => [
              %{"key" => "xyz123abc", "site" => "YouTube", "type" => "Trailer"}
            ]
          }
        })

      assert {:ok, %{data: %{"tvShow" => %{"trailerUrl" => url}}}} =
               run_query(@show_trailer_query, %{"id" => show.id}, ctx.user)

      assert url == "https://www.youtube.com/watch?v=xyz123abc"
    end

    test "is null when there are no videos", ctx do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show"})

      assert {:ok, %{data: %{"tvShow" => %{"trailerUrl" => nil}}}} =
               run_query(@show_trailer_query, %{"id" => show.id}, ctx.user)
    end
  end

  describe "movie.cast" do
    test "returns cast members with a built profile URL", ctx do
      movie =
        MediaFixtures.media_item_fixture(%{
          type: "movie",
          metadata: %{
            "provider_id" => "603",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "The Matrix",
            "cast" => [
              %{
                "name" => "Keanu Reeves",
                "character" => "Neo",
                "order" => 0,
                "profile_path" => "/abc.jpg"
              }
            ]
          }
        })

      assert {:ok, %{data: %{"movie" => %{"cast" => [member]}}}} =
               run_query(@movie_cast_query, %{"id" => movie.id}, ctx.user)

      assert member["name"] == "Keanu Reeves"
      assert member["character"] == "Neo"
      assert member["profileUrl"] == "https://image.tmdb.org/t/p/w185/abc.jpg"
    end

    test "is an empty list when there is no cast", ctx do
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})

      assert {:ok, %{data: %{"movie" => %{"cast" => []}}}} =
               run_query(@movie_cast_query, %{"id" => movie.id}, ctx.user)
    end
  end

  describe "tvShow.cast" do
    test "returns cast members with a built profile URL", ctx do
      show =
        MediaFixtures.media_item_fixture(%{
          type: "tv_show",
          metadata: %{
            "provider_id" => "1396",
            "provider" => "metadata_relay",
            "media_type" => "tv_show",
            "title" => "Breaking Bad",
            "cast" => [
              %{
                "name" => "Bryan Cranston",
                "character" => "Walter White",
                "order" => 0,
                "profile_path" => "/def.jpg"
              }
            ]
          }
        })

      assert {:ok, %{data: %{"tvShow" => %{"cast" => [member]}}}} =
               run_query(@show_cast_query, %{"id" => show.id}, ctx.user)

      assert member["name"] == "Bryan Cranston"
      assert member["character"] == "Walter White"
      assert member["profileUrl"] == "https://image.tmdb.org/t/p/w185/def.jpg"
    end

    test "is an empty list when there is no cast", ctx do
      show = MediaFixtures.media_item_fixture(%{type: "tv_show"})

      assert {:ok, %{data: %{"tvShow" => %{"cast" => []}}}} =
               run_query(@show_cast_query, %{"id" => show.id}, ctx.user)
    end
  end

  defp run_query(query, variables, user) do
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: %{current_user: user})
  end
end
