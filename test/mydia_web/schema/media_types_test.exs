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

  defp run_query(query, variables, user) do
    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: %{current_user: user})
  end
end
