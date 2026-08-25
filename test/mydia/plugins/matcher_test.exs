defmodule Mydia.Plugins.MatcherTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Plugins.Matcher

  defp movie(attrs) do
    {:ok, item} =
      Media.create_media_item(
        Scope.unrestricted(),
        Map.merge(
          %{
            title: "Movie",
            type: "movie",
            year: 2024,
            tmdb_id: System.unique_integer([:positive])
          },
          attrs
        )
      )

    item
  end

  defp show(attrs) do
    {:ok, item} =
      Media.create_media_item(
        Scope.unrestricted(),
        Map.merge(
          %{title: "Show", type: "tv_show", tmdb_id: System.unique_integer([:positive])},
          attrs
        ),
        skip_episode_refresh: true
      )

    item
  end

  defp episode(show, season, number) do
    {:ok, ep} =
      Media.create_episode(%{
        media_item_id: show.id,
        season_number: season,
        episode_number: number,
        title: "Ep"
      })

    ep
  end

  test "matches a movie by imdb id (the first ordered candidate)" do
    m = movie(%{imdb_id: "tt100"})
    assert {:movie, id} = Matcher.match(%{imdb: "tt100"})
    assert id == m.id
  end

  test "matches an episode via the show's external id and coordinates" do
    s = show(%{tvdb_id: 555})
    ep = episode(s, 1, 2)

    assert {:episode, id} = Matcher.match(%{tvdb: 555, season: 1, episode: 2})
    assert id == ep.id
  end

  test "unmatched external ids return not_found" do
    assert :not_found = Matcher.match(%{imdb: "tt-does-not-exist"})
  end

  test "a resolved show with a missing episode returns not_found (no fall-through)" do
    s = show(%{tvdb_id: 777})
    _ep = episode(s, 1, 1)

    # The show resolves, but S09E09 does not exist — must not fall through to the
    # show or any other episode.
    assert :not_found = Matcher.match(%{tvdb: 777, season: 9, episode: 9})
  end

  test "no coordinates resolves via the movie path" do
    m = movie(%{tmdb_id: 4242})
    assert {:movie, id} = Matcher.match(%{tmdb: 4242})
    assert id == m.id
  end

  describe "match_item/1" do
    test "resolves a show by external ids without episode coordinates" do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", tvdb_id: 424_242})

      assert {:media_item, id} = Matcher.match_item(%{tvdb: 424_242})
      assert id == show.id
    end

    test "returns :not_found for unknown ids" do
      assert :not_found = Matcher.match_item(%{tvdb: 999_999_999})
    end
  end

  test "match_item resolves a show as well as a movie" do
    s = show(%{tvdb_id: 4242})

    assert {:media_item, id} = Matcher.match_item(%{tvdb: 4242})
    assert id == s.id
  end

  test "an episode target does not resolve to a like-numbered movie" do
    # The movie owns the imdb id the show's target also carries. Without a type
    # filter the cascade stops on the movie and the episode is never found.
    _decoy = movie(%{imdb_id: "tt5150"})
    s = show(%{tvdb_id: 5150})
    ep = episode(s, 2, 3)

    assert {:episode, id} = Matcher.match(%{imdb: "tt5150", tvdb: 5150, season: 2, episode: 3})
    assert id == ep.id
  end
end
