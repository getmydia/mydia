defmodule Mydia.Downloads.CandidatePoolTest do
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.Structs.CandidatePool
  alias Mydia.Downloads.{ReleaseIntake, TorrentMatcher}

  import Mydia.MediaFixtures

  defp parsed(name) do
    {:ok, info} = ReleaseIntake.parse_release(name)
    info
  end

  describe "load/1" do
    test "splits the library into movies and tv shows" do
      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
      show = media_item_fixture(%{type: "tv_show", title: "The Bear"})

      pool = CandidatePool.load()

      assert Enum.map(pool.movies, & &1.id) == [movie.id]
      assert Enum.map(pool.tv_shows, & &1.id) == [show.id]
    end

    test "monitored_only restricts both sides" do
      media_item_fixture(%{type: "movie", title: "Unwatched", monitored: false})
      watched = media_item_fixture(%{type: "movie", title: "Watched", monitored: true})

      pool = CandidatePool.load(monitored_only: true)

      assert Enum.map(pool.movies, & &1.id) == [watched.id]
    end
  end

  describe "find_top_candidates_in/3" do
    test "scores against the pool it is given, not the database" do
      media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
      empty_pool = %CandidatePool{movies: [], tv_shows: []}

      assert TorrentMatcher.find_top_candidates_in(
               empty_pool,
               parsed("The.Matrix.1999.1080p.BluRay.x264-GROUP")
             ) == []
    end

    test "agrees with find_top_candidates/2 for the same library" do
      media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
      info = parsed("The.Matrix.1999.1080p.BluRay.x264-GROUP")

      from_db = TorrentMatcher.find_top_candidates(info)
      from_pool = TorrentMatcher.find_top_candidates_in(CandidatePool.load(), info)

      assert from_pool == from_db
      assert [%{title: "The Matrix"} | _] = from_pool
    end
  end
end
