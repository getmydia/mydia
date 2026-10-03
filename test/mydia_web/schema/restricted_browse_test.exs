defmodule MydiaWeb.Schema.RestrictedBrowseTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Accounts.Scope
  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias MydiaWeb.Schema.Resolvers.NodeId

  setup do
    movie =
      MediaFixtures.categorized_media_item_fixture(
        %{type: "movie", title: "Glass Orchard"},
        "movie"
      )

    show =
      MediaFixtures.categorized_media_item_fixture(
        %{type: "tv_show", title: "Northbound Lanterns"},
        "tv_show"
      )

    episode = MediaFixtures.episode_fixture(%{media_item_id: show.id, season_number: 1})

    # Add media files so they show up in list queries (which use has_files: true)
    MediaFixtures.media_file_fixture(%{media_item_id: movie.id})
    MediaFixtures.media_file_fixture(%{episode_id: episode.id})

    restricted =
      AccountsFixtures.restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    unrestricted = AccountsFixtures.user_fixture()

    %{
      movie: movie,
      show: show,
      episode: episode,
      restricted: restricted,
      unrestricted: unrestricted
    }
  end

  defp run(query, variables, user) do
    Absinthe.run(query, MydiaWeb.Schema,
      variables: variables,
      context: %{current_user: user, current_scope: Scope.for_user(user)}
    )
  end

  test "tvShow returns the show for unrestricted users", ctx do
    {:ok, result} =
      run("query($id: ID!) { tvShow(id: $id) { id } }", %{"id" => ctx.show.id}, ctx.unrestricted)

    assert %{data: %{"tvShow" => %{"id" => _}}} = result
  end

  test "tvShow hides the show from restricted users", ctx do
    {:ok, result} =
      run("query($id: ID!) { tvShow(id: $id) { id } }", %{"id" => ctx.show.id}, ctx.restricted)

    assert %{data: %{"tvShow" => nil}, errors: [%{message: "TV show not found"}]} = result
  end

  test "episode hides the episode", ctx do
    {:ok, result} =
      run(
        "query($id: ID!) { episode(id: $id) { id } }",
        %{"id" => ctx.episode.id},
        ctx.restricted
      )

    assert %{data: %{"episode" => nil}, errors: [%{message: "Episode not found"}]} = result
  end

  test "node hides movie, show, episode and season ids", ctx do
    ids = [
      NodeId.encode(:movie, ctx.movie.id),
      NodeId.encode(:tv_show, ctx.show.id),
      NodeId.encode(:episode, ctx.episode.id),
      NodeId.encode(:season, ctx.show.id, 1)
    ]

    for id <- ids do
      {:ok, result} =
        run("query($id: ID!) { node(id: $id) { id } }", %{"id" => id}, ctx.restricted)

      assert %{data: %{"node" => nil}, errors: [_ | _]} = result, "node #{id} leaked"
    end
  end

  test "seasonEpisodes is empty for a hidden show", ctx do
    {:ok, result} =
      run(
        "query($id: ID!) { seasonEpisodes(showId: $id, seasonNumber: 1) { id } }",
        %{"id" => ctx.show.id},
        ctx.restricted
      )

    assert %{data: %{"seasonEpisodes" => []}} = result
  end

  test "movies and tvShows include all titles for unrestricted users", ctx do
    {:ok, result} =
      run(
        "query { movies(first: 50) { edges { node { id } } } tvShows(first: 50) { edges { node { id } } } }",
        %{},
        ctx.unrestricted
      )

    ids =
      for list <- [result.data["movies"], result.data["tvShows"]],
          %{"node" => %{"id" => id}} <- list["edges"],
          do: id

    assert ctx.movie.id in ids
    assert ctx.show.id in ids
  end

  test "movies and tvShows omit hidden titles for restricted users", ctx do
    {:ok, result} =
      run(
        "query { movies(first: 50) { edges { node { id } } } tvShows(first: 50) { edges { node { id } } } }",
        %{},
        ctx.restricted
      )

    ids =
      for list <- [result.data["movies"], result.data["tvShows"]],
          %{"node" => %{"id" => id}} <- list["edges"],
          do: id

    refute ctx.movie.id in ids
    refute ctx.show.id in ids
  end
end
