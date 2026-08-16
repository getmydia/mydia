defmodule Mydia.Library.BatchMatcherTest do
  @moduledoc """
  The point of this module is call collapsing, so the assertions are about how
  many times the relay was hit, not about match quality.

  async: false because Mydia.Metadata.Cache is a global ETS table.
  """
  use ExUnit.Case, async: false

  alias Mydia.Library.BatchMatcher
  alias Mydia.Metadata.Cache

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    counter = :counters.new(1, [:atomics])

    # BatchMatcher fans work out across freshly spawned Task processes, and
    # match_file/2 checks the local database for an existing match before it
    # ever reaches the relay. Share this test's sandbox connection so those
    # spawned tasks can query it too.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Mydia.Metadata.Cache is global, named ETS with no other test-suite
    # reset, so clear it on the way in and on the way out (same idiom as
    # Mydia.MetadataStub.setup_metadata_stub/1). Deleting by hand-computed key
    # instead of clearing was tried and desynced the moment a stub's response
    # shape changed which of MetadataMatcher's search branches ran (see the
    # comment on the cleanup-proof test below) -- a clear cannot drift out of
    # sync with the code under test.
    Cache.clear()
    on_exit(fn -> Cache.clear() end)

    {:ok, bypass: bypass, config: config, counter: counter}
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  test "issues one search for a whole season rather than one per episode", %{
    bypass: bypass,
    config: config,
    counter: counter
  } do
    Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
      :counters.add(counter, 1, 1)

      json(conn, %{
        "results" => [
          %{"id" => 82_728, "name" => "Bluey", "first_air_date" => "2018-10-01"}
        ]
      })
    end)

    Bypass.stub(bypass, "GET", "/tmdb/tv/82728", fn conn ->
      json(conn, %{"id" => 82_728, "name" => "Bluey", "seasons" => []})
    end)

    paths =
      for ep <- 1..12 do
        "/media/tv/Bluey/Season 01/Bluey.S01E#{String.pad_leading(to_string(ep), 2, "0")}.mkv"
      end

    results = BatchMatcher.match_paths(paths, config: config, provider: :tmdb)

    assert length(results) == 12
    assert :counters.get(counter, 1) == 1
  end

  test "searches once per distinct title", %{bypass: bypass, config: config, counter: counter} do
    Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
      :counters.add(counter, 1, 1)
      json(conn, %{"results" => []})
    end)

    # A movie hit needs a real result, not an empty one: MetadataMatcher retries
    # once *without* the year filter whenever a with-year search comes back
    # empty, and that retry is a second, differently-keyed relay call — a
    # genuine two-step lookup, not the duplicate-search problem BatchMatcher
    # collapses. An empty stub here would make this test conflate the two and
    # assert a call count that has nothing to do with grouping.
    Bypass.expect(bypass, "GET", "/tmdb/movies/search", fn conn ->
      :counters.add(counter, 1, 1)

      json(conn, %{
        "results" => [
          %{"id" => 603, "title" => "The Matrix", "release_date" => "1999-03-30"}
        ]
      })
    end)

    paths = [
      "/media/tv/Bluey/Season 01/Bluey.S01E01.mkv",
      "/media/tv/Bluey/Season 01/Bluey.S01E02.mkv",
      "/media/movies/The.Matrix.1999.1080p.mkv"
    ]

    _results = BatchMatcher.match_paths(paths, config: config, provider: :tmdb)

    # One TV search for Bluey, one movie search for The Matrix.
    assert :counters.get(counter, 1) == 2
  end

  test "returns a result for every input path even when matching fails", %{
    bypass: bypass,
    config: config
  } do
    Bypass.stub(bypass, "GET", "/tmdb/tv/search", fn conn -> json(conn, %{"results" => []}) end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      json(conn, %{"results" => []})
    end)

    paths = [
      "/media/tv/Bluey/Season 01/Bluey.S01E01.mkv",
      "/media/movies/Totally.Unmatchable.Thing.mkv"
    ]

    results = BatchMatcher.match_paths(paths, config: config, provider: :tmdb)

    assert length(results) == 2
    assert Enum.all?(results, fn {path, _} -> path in paths end)
  end

  @tag :capture_log
  test "a provider payload that crashes the matcher fails only that file", %{
    bypass: bypass,
    config: config
  } do
    Bypass.stub(bypass, "GET", "/tmdb/tv/search", fn conn -> json(conn, %{"results" => []}) end)

    # A search result that is not a map. `SearchResult.from_api_response/2`
    # guards on `is_map/1`, so this raises inside the matcher task -- the
    # realistic shape of "the provider returned something this code does not
    # parse", which is all MetadataMatcher.match_file/2 needs to raise.
    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      json(conn, %{"results" => ["not a result object"]})
    end)

    tv_paths = [
      "/media/tv/Bluey/Season 01/Bluey.S01E01.mkv",
      "/media/tv/Bluey/Season 01/Bluey.S01E02.mkv"
    ]

    movie_path = "/media/movies/The.Matrix.1999.1080p.mkv"
    paths = tv_paths ++ [movie_path]

    results = BatchMatcher.match_paths(paths, config: config, provider: :tmdb)

    # The load-bearing assertion. Before this was contained, the raise
    # travelled up the link from the task to whoever called match_paths/2 and
    # killed it -- in production the import coordinator, mid-chunk. Every input
    # path must still come back with exactly one result, because
    # Jobs.ImportRun's match loop reselects any file that got none, forever.
    assert length(results) == 3
    assert Enum.sort(Enum.map(results, &elem(&1, 0))) == Enum.sort(paths)

    assert {^movie_path, {:error, {:matcher_crashed, _}}} =
             Enum.find(results, fn {path, _result} -> path == movie_path end)

    # And the two files that did not crash were matched on their own merits
    # rather than being failed alongside the one that did.
    for tv_path <- tv_paths do
      assert {^tv_path, {:error, reason}} =
               Enum.find(results, fn {path, _result} -> path == tv_path end)

      refute match?({:matcher_crashed, _}, reason)
    end
  end

  @tag :capture_log
  test "a progress callback that raises fails its own group, not the batch", %{
    bypass: bypass,
    config: config
  } do
    # Nothing malformed here: the relay answers both searches normally. What
    # blows up is the caller-supplied `:on_result` callback, which runs inside
    # the worker but outside the per-file guard, so this is the path that
    # reaches the stream's own `{:exit, reason}` handling.
    Bypass.stub(bypass, "GET", "/tmdb/tv/search", fn conn -> json(conn, %{"results" => []}) end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
      json(conn, %{"results" => []})
    end)

    test_pid = self()
    tv_path = "/media/tv/Bluey/Season 01/Bluey.S01E01.mkv"
    movie_path = "/media/movies/The.Matrix.1999.1080p.mkv"

    results =
      BatchMatcher.match_paths([tv_path, movie_path],
        config: config,
        provider: :tmdb,
        on_result: fn
          ^movie_path, _result -> raise "progress callback blew up"
          path, _result -> send(test_pid, {:progress, path})
        end
      )

    assert length(results) == 2

    assert {^movie_path, {:error, {:matcher_crashed, _}}} =
             Enum.find(results, fn {path, _result} -> path == movie_path end)

    assert {^tv_path, _result} = Enum.find(results, fn {path, _} -> path == tv_path end)
    assert_receive {:progress, ^tv_path}, 1_000
  end

  test "invokes the progress callback once per file", %{bypass: bypass, config: config} do
    Bypass.stub(bypass, "GET", "/tmdb/tv/search", fn conn -> json(conn, %{"results" => []}) end)

    test_pid = self()

    paths = [
      "/media/tv/Bluey/Season 01/Bluey.S01E01.mkv",
      "/media/tv/Bluey/Season 01/Bluey.S01E02.mkv"
    ]

    BatchMatcher.match_paths(paths,
      config: config,
      provider: :tmdb,
      on_result: fn path, _result -> send(test_pid, {:progress, path}) end
    )

    assert_receive {:progress, _}, 1_000
    assert_receive {:progress, _}, 1_000
  end

  test "clears the cache entry a movie search leaves behind, proving cleanup rather than assuming it",
       %{bypass: bypass, config: config} do
    # A prior version of this suite cleaned up by deleting a hand-computed key
    # ("search:metadata_relay:The Matrix:movie::en-US:1", no year) that
    # matched the *year-less retry* MetadataMatcher.search_external_movie/2
    # falls back to when the first search returns no results. Once the movie
    # stub below returns a real match, the with-year search succeeds on the
    # first try, the retry never fires, and the entry actually left behind
    # carries the parsed year -- a different key the old delete silently
    # missed, leaking a global ETS entry across tests. Reproduce that real key
    # here and prove `Cache.clear/0` (used in `setup`/`on_exit` above) wipes
    # it, instead of just trusting that it does.
    Bypass.expect(bypass, "GET", "/tmdb/movies/search", fn conn ->
      json(conn, %{
        "results" => [
          %{"id" => 603, "title" => "The Matrix", "release_date" => "1999-03-30"}
        ]
      })
    end)

    key = "search:metadata_relay:The Matrix:movie:1999:en-US:1"

    assert {:error, :not_found} = Cache.get(key)

    results =
      BatchMatcher.match_paths(["/media/movies/The.Matrix.1999.1080p.mkv"],
        config: config,
        provider: :tmdb
      )

    assert [{_path, {:ok, _match}}] = results

    # The entry genuinely exists now -- without this, the assertion after
    # `Cache.clear/0` below would pass trivially even if clearing were broken
    # or never ran.
    assert {:ok, _cached} = Cache.get(key)

    Cache.clear()

    assert {:error, :not_found} = Cache.get(key)
  end
end
