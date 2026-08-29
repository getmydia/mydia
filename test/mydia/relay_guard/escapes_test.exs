defmodule Mydia.RelayGuard.EscapesTest do
  # The escape table is global, named and public. async: false modules run
  # alone, which keeps these assertions from seeing another test's escapes.
  use ExUnit.Case, async: false

  alias Mydia.RelayGuard.Escapes

  setup do
    Escapes.setup()
    Escapes.reset()
    on_exit(&Escapes.reset/0)
    :ok
  end

  defp request(url), do: Req.new(url: url)

  test "records a blocked request" do
    Escapes.record(request("https://relay.mydia.dev/tmdb/movies/900000123"))

    assert [{_key, 1, url, _frames}] = Escapes.all()
    assert url == "https://relay.mydia.dev/tmdb/movies/900000123"
  end

  test "deduplicates repeats of the same request into one counted row" do
    req = request("https://relay.mydia.dev/tmdb/movies/900000123")

    Escapes.record(req)
    Escapes.record(req)
    Escapes.record(req)

    assert [{_key, 3, _url, _frames}] = Escapes.all()
  end

  test "records distinct paths separately" do
    Escapes.record(request("https://relay.mydia.dev/tmdb/movies/900000123"))
    Escapes.record(request("https://relay.mydia.dev/tmdb/movies/900000456"))

    assert length(Escapes.all()) == 2
  end

  test "records two requests for the same movie id with different append_to_response queries as two rows" do
    Escapes.record(
      request("https://relay.mydia.dev/tmdb/movies/900000123?append_to_response=recommendations")
    )

    Escapes.record(
      request(
        "https://relay.mydia.dev/tmdb/movies/900000123?append_to_response=credits,alternative_titles,videos,external_ids"
      )
    )

    assert length(Escapes.all()) == 2
  end

  test "the recorded frames exclude the guard's own modules" do
    Escapes.record(request("https://relay.mydia.dev/tmdb/movies/900000123"))

    assert [{_key, _count, _url, frames}] = Escapes.all()

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

  test "suggests nothing for an unrecognised path" do
    refute Escapes.suggest("/some/other/path", nil)
  end

  test "the report names the url and the fix" do
    Escapes.record(request("https://relay.mydia.dev/tmdb/collections/900000123"))

    report = Escapes.format(Escapes.all())

    assert report =~ "https://relay.mydia.dev/tmdb/collections/900000123"
    assert report =~ "warm_collection_cache(900000123, parts)"
    assert report =~ "escaped to the network"
  end
end
