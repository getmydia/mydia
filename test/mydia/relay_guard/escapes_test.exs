defmodule Mydia.RelayGuard.EscapesTest do
  # The escape table is global, named and public, and shared with the rest of
  # the suite, which runs with the guard armed from test_helper.exs and reads
  # Escapes.all() at the end expecting a complete account of what was
  # blocked. This module must not call Escapes.reset/0: it used to, in both
  # setup and on_exit, which wiped every escape the rest of the suite had
  # recorded before this module happened to run — the actual cause of the
  # end-of-suite report under-counting real escapes (#530). async: false
  # keeps another MODULE from interleaving with this one; a unique id per
  # test below is what keeps this module's own tests, and the rest of the
  # suite, from polluting each other's counts.
  use ExUnit.Case, async: false

  alias Mydia.RelayGuard.Escapes

  setup do
    Escapes.setup()
    :ok
  end

  defp request(url), do: Req.new(url: url)

  defp unique_id, do: System.unique_integer([:positive])

  # Registers on_exit cleanup for a url a test is about to record, so the row
  # does not linger in the shared table once the test is done — otherwise the
  # end-of-suite report would flag it as if it were a real, unwarmed
  # application escape rather than this module's own test fixture.
  defp track(url) do
    on_exit(fn -> Escapes.delete(url) end)
    url
  end

  defp rows_for(urls) when is_list(urls) do
    Enum.filter(Escapes.all(), fn {_key, _count, url, _frames} -> url in urls end)
  end

  defp rows_for(url), do: rows_for([url])

  test "records a blocked request" do
    url = track("https://relay.mydia.dev/tmdb/movies/#{unique_id()}")

    Escapes.record(request(url))

    assert [{_key, 1, recorded_url, _frames}] = rows_for(url)
    assert recorded_url == url
  end

  test "deduplicates repeats of the same request into one counted row" do
    url = track("https://relay.mydia.dev/tmdb/movies/#{unique_id()}")
    req = request(url)

    Escapes.record(req)
    Escapes.record(req)
    Escapes.record(req)

    assert [{_key, 3, _url, _frames}] = rows_for(url)
  end

  test "records distinct paths separately" do
    url1 = track("https://relay.mydia.dev/tmdb/movies/#{unique_id()}")
    url2 = track("https://relay.mydia.dev/tmdb/movies/#{unique_id()}")

    Escapes.record(request(url1))
    Escapes.record(request(url2))

    assert length(rows_for([url1, url2])) == 2
  end

  test "records two requests for the same movie id with different append_to_response queries as two rows" do
    id = unique_id()
    url1 = track("https://relay.mydia.dev/tmdb/movies/#{id}?append_to_response=recommendations")

    url2 =
      track(
        "https://relay.mydia.dev/tmdb/movies/#{id}?append_to_response=credits,alternative_titles,videos,external_ids"
      )

    Escapes.record(request(url1))
    Escapes.record(request(url2))

    assert length(rows_for([url1, url2])) == 2
  end

  test "the recorded frames exclude the guard's own modules" do
    url = track("https://relay.mydia.dev/tmdb/movies/#{unique_id()}")

    Escapes.record(request(url))

    assert [{_key, _count, _url, frames}] = rows_for(url)

    refute Enum.any?(frames, fn {mod, _fun, _arity, _loc} ->
             mod == Mydia.RelayGuard or
               mod |> Atom.to_string() |> String.starts_with?("Elixir.Mydia.RelayGuard.")
           end)
  end

  test "suggests the collection helper for a collection path" do
    assert Escapes.suggest("/tmdb/collections/900000123", nil) ==
             "warm_collection_cache(900000123, parts)"
  end

  test "suggests the recommendations helper for a tv path" do
    assert Escapes.suggest("/tmdb/tv/shows/900000123", nil) ==
             "warm_recommendations_cache(900000123, :tv_show, results)"
  end

  test "disambiguates a movie path by the append_to_response query" do
    assert Escapes.suggest("/tmdb/movies/900000123", "append_to_response=recommendations") ==
             "warm_recommendations_cache(900000123, :movie, results)"

    assert Escapes.suggest(
             "/tmdb/movies/900000123",
             "append_to_response=credits,alternative_titles,videos,external_ids"
           ) == "warm_movie_details_cache(900000123)"
  end

  test "suggests the trending helper for movies and tv" do
    assert Escapes.suggest("/tmdb/movies/trending", nil) ==
             "warm_trending_cache(:movie, results)"

    assert Escapes.suggest("/tmdb/tv/trending", nil) ==
             "warm_trending_cache(:tv_show, results)"
  end

  test "suggests the genre helper for movies and tv" do
    assert Escapes.suggest("/tmdb/genre/movie", nil) ==
             "warm_genre_cache(:movie, genres)"

    assert Escapes.suggest("/tmdb/genre/tv", nil) ==
             "warm_genre_cache(:tv_show, genres)"
  end

  test "suggests the movie search helper, carrying the query and year through" do
    assert Escapes.suggest(
             "/tmdb/movies/search",
             "query=Ratatouille&language=en-US&include_adult=false&page=1&year=2007"
           ) == "warm_movie_search_cache(\"Ratatouille\", [year: 2007], results)"
  end

  test "suggests the movie search helper with no year when none was searched" do
    assert Escapes.suggest("/tmdb/movies/search", "query=Ratatouille&language=en-US") ==
             "warm_movie_search_cache(\"Ratatouille\", [], results)"
  end

  test "suggests nothing for a movie search path with no parseable query" do
    refute Escapes.suggest("/tmdb/movies/search", nil)
    refute Escapes.suggest("/tmdb/movies/search", "language=en-US")
  end

  test "suggests nothing for a tvdb search path (uncached, no safe suggestion)" do
    refute Escapes.suggest("/tvdb/search", "query=Test&type=series")
  end

  test "suggests nothing for an unrecognised path" do
    refute Escapes.suggest("/some/other/path", nil)
  end

  test "the report names the url and the fix" do
    id = unique_id()
    url = track("https://relay.mydia.dev/tmdb/collections/#{id}")

    Escapes.record(request(url))

    report = Escapes.format(rows_for(url))

    assert report =~ url
    assert report =~ "warm_collection_cache(#{id}, parts)"
    assert report =~ "escaped to the network"
  end
end
