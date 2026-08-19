defmodule Mydia.Library.MetadataMatcherScoringTest do
  @moduledoc """
  Candidate selection, driven through the real entry points.

  Every test here calls `match_tv_show/3` or `match_movie/3` against a stubbed
  relay, so the assertions are about which candidate wins and whether the
  winner clears the auto-accept bar. The scoring functions themselves are
  private and stay that way.

  This replaces the `test_*` re-implementations that used to carry this
  coverage in `metadata_matcher_test.exs`. A replica cannot fail when the
  original changes, and that one had already drifted: `normalize_test_title/1`
  was missing the NFKD fold and the `/u` regex flag, so it deleted accented
  characters ("têtes" -> "ttes") where production folds them ("tetes"). On a
  library of French titles that is not a hypothetical difference.

  async: false because Mydia.Metadata.Cache is a global ETS table.
  """
  use Mydia.DataCase, async: false

  alias Mydia.ImportGroups
  alias Mydia.Library.MetadataMatcher
  alias Mydia.Metadata.Cache

  @tvdb_search "/tvdb/search"
  @tmdb_tv_search "/tmdb/tv/search"
  @tmdb_movie_search "/tmdb/movies/search"

  # TV searches route to TVDB unless a provider is named. The popularity-driven
  # cases below need TMDB, which is the only source that sends the field.
  @tmdb [provider: :tmdb]

  @bluey %{"id" => 82_728, "name" => "Bluey", "first_air_date" => "2018-10-01"}
  @bluey_spin_off %{
    "id" => 225_191,
    "name" => "Bluey Cookalongs",
    "first_air_date" => "2023-09-01"
  }

  @office_us %{"id" => 2316, "name" => "The Office", "first_air_date" => "2005-03-24"}
  @office_uk %{"id" => 2987, "name" => "The Office", "first_air_date" => "2001-07-09"}

  # Verbatim from TVDB via relay.mydia.dev on 2026-08-18. The library folder is
  # "Passe-Partout (2018)"; the 2019 revival is the right answer and the 1977
  # original is the wrong one.
  @passe_partout [
    %{
      "tvdb_id" => 117_091,
      "name" => "Passe-Partout",
      "year" => "1977",
      "first_air_time" => "1977-11-14"
    },
    %{
      "tvdb_id" => 356_390,
      "name" => "Passe-Partout (2019)",
      "year" => "2019",
      "first_air_time" => "2019-02-25"
    }
  ]

  # A popular original and its popular remake sharing a title on TMDB is the
  # movie shape of the Passe-Partout problem.
  @dune [
    %{"id" => 841, "title" => "Dune", "release_date" => "1984-12-14", "popularity" => 120.0},
    %{"id" => 438_631, "title" => "Dune", "release_date" => "2021-09-15", "popularity" => 300.0}
  ]

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    Cache.clear()
    on_exit(fn -> Cache.clear() end)

    {:ok, bypass: bypass, config: config}
  end

  defp stub(bypass, path, body) do
    Bypass.stub(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp results(list), do: %{"results" => list}
  defp data(list), do: %{"data" => list}

  defp with_popularity(show, popularity), do: Map.put(show, "popularity", popularity)

  defp tvdb_show(id, name, year) do
    %{
      "tvdb_id" => id,
      "name" => name,
      "year" => to_string(year),
      "first_air_time" => "#{year}-01-01"
    }
  end

  defp tmdb_movie(id, title, release_date, popularity) do
    %{"id" => id, "title" => title, "release_date" => release_date, "popularity" => popularity}
  end

  defp tv(title, year) do
    %{type: :tv_show, title: title, year: year, season: 1, episodes: [1], confidence: 1.0}
  end

  defp movie(title, year) do
    %{type: :movie, title: title, year: year, quality: %{}, confidence: 1.0}
  end

  # Scores one TMDB TV candidate on its own, which is how a margin between two
  # candidates gets measured without reaching into the private scorer.
  # `Metadata.search_cached/3` keys on the query, so the cache has to be cleared
  # between two calls searching the same title with different stubbed results,
  # or the second silently re-reads the first's.
  defp tmdb_tv_confidence(bypass, config, parsed, show) do
    Cache.clear()
    stub(bypass, @tmdb_tv_search, results([show]))
    {:ok, match} = MetadataMatcher.match_tv_show(parsed, config, @tmdb)
    match.match_confidence
  end

  describe "match_tv_show/3" do
    test "matches an exact title and year", %{bypass: bypass, config: config} do
      stub(bypass, @tvdb_search, data([tvdb_show(1396, "Breaking Bad", 2008)]))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Breaking Bad", 2008), config)
      assert match.provider_id == "1396"
      assert match.match_confidence >= 0.9
    end

    test "matches despite case differences when the folder carries no year", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tvdb_search, data([tvdb_show(1399, "Game of Thrones", 2011)]))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Game Of Thrones", nil), config)
      assert match.provider_id == "1399"
    end
  end

  describe "match_movie/3" do
    test "matches an exact title and year", %{bypass: bypass, config: config} do
      stub(
        bypass,
        @tmdb_movie_search,
        results([tmdb_movie(603, "The Matrix", "1999-03-31", 50.5)])
      )

      assert {:ok, match} = MetadataMatcher.match_movie(movie("The Matrix", 1999), config)
      assert match.provider_id == "603"
      assert match.match_confidence >= 0.9
    end

    test "matches a title the parser stripped the punctuation from", %{
      bypass: bypass,
      config: config
    } do
      stub(
        bypass,
        @tmdb_movie_search,
        results([
          tmdb_movie(120, "The Lord of the Rings: The Fellowship of the Ring", "2001-12-19", 80.0)
        ])
      )

      parsed = movie("The Lord Of The Rings The Fellowship Of The Ring", 2001)
      assert {:ok, match} = MetadataMatcher.match_movie(parsed, config)
      assert match.provider_id == "120"
    end

    test "tolerates a release year off by one", %{bypass: bypass, config: config} do
      # Regional release dates drift; ±1 is deliberate slack, not a contradiction.
      stub(
        bypass,
        @tmdb_movie_search,
        results([tmdb_movie(27_205, "Inception", "2009-12-16", 60.0)])
      )

      assert {:ok, match} = MetadataMatcher.match_movie(movie("Inception", 2010), config)
      assert match.provider_id == "27205"
      assert match.match_confidence >= ImportGroups.auto_accept_threshold()
    end
  end

  describe "main series vs spin-off" do
    test "the main series wins, and by a clear margin", %{bypass: bypass, config: config} do
      main = with_popularity(@bluey, 200.0)
      spin_off = with_popularity(@bluey_spin_off, 15.0)

      stub(bypass, @tmdb_tv_search, results([main, spin_off]))

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Bluey", nil), config, @tmdb)

      assert match.provider_id == "82728"

      main_score = tmdb_tv_confidence(bypass, config, tv("Bluey", nil), main)
      spin_off_score = tmdb_tv_confidence(bypass, config, tv("Bluey", nil), spin_off)

      assert main_score - spin_off_score >= 0.1,
             "margin was #{main_score - spin_off_score} " <>
               "(main #{main_score}, spin-off #{spin_off_score})"
    end

    test "the exact title still wins when popularity is equal", %{bypass: bypass, config: config} do
      stub(
        bypass,
        @tmdb_tv_search,
        results([with_popularity(@bluey, 50.0), with_popularity(@bluey_spin_off, 50.0)])
      )

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Bluey", nil), config, @tmdb)
      assert match.provider_id == "82728"
    end

    test "a longer derivative is penalised more than a shorter one", %{
      bypass: bypass,
      config: config
    } do
      short = %{
        "id" => 1,
        "name" => "Bluey: Special",
        "first_air_date" => "2023-01-01",
        "popularity" => 50.0
      }

      long = %{
        "id" => 2,
        "name" => "Bluey Cookalongs: The Complete Collection",
        "first_air_date" => "2023-01-01",
        "popularity" => 50.0
      }

      short_score = tmdb_tv_confidence(bypass, config, tv("Bluey", nil), short)
      long_score = tmdb_tv_confidence(bypass, config, tv("Bluey", nil), long)

      assert short_score > long_score,
             "short #{short_score} should beat long #{long_score}"
    end
  end

  describe "two shows sharing a title exactly" do
    test "both saturate the score cap, so popularity cannot separate them", %{
      bypass: bypass,
      config: config
    } do
      # The Office US vs UK. An exact title with a known year already sums past
      # 1.0 before popularity is added (0.5 base + 0.25 similarity + 0.1 year +
      # 0.05 first_air_date + 0.15 exact), so `min(score, 1.0)` flattens the two
      # apart. Popularity is a real tiebreaker only where the title is *not*
      # exact, which the spin-off cases above cover.
      #
      # The replica this replaced asserted `us_score >= uk_score` and passed on
      # the tie without anyone noticing the tiebreaker was inert.
      us =
        tmdb_tv_confidence(
          bypass,
          config,
          tv("The Office", nil),
          with_popularity(@office_us, 100.0)
        )

      uk =
        tmdb_tv_confidence(
          bypass,
          config,
          tv("The Office", nil),
          with_popularity(@office_uk, 10.0)
        )

      assert us == 1.0
      assert uk == 1.0
    end

    test "the parsed year is what actually separates them", %{bypass: bypass, config: config} do
      stub(
        bypass,
        @tmdb_tv_search,
        results([with_popularity(@office_uk, 10.0), with_popularity(@office_us, 100.0)])
      )

      # The UK original is listed first, so a tie would hand it the match.
      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("The Office", 2005), config, @tmdb)
      assert match.provider_id == "2316"
    end
  end

  describe "a same-title reboot" do
    test "is picked over the original when the parsed year says so", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tvdb_search, data(@passe_partout))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Passe-Partout", 2018), config)

      assert match.provider_id == "356390",
             "picked #{match.title} (#{match.year}) at #{match.match_confidence}; " <>
               "2018 is one year off the 2019 revival and 41 off the original"
    end

    test "does not displace the original when the parsed year agrees with it", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tvdb_search, data(@passe_partout))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Passe-Partout", 1977), config)
      assert match.provider_id == "117091"
    end
  end

  describe "a contradicted year" do
    test "keeps an exact-title match below the auto-accept threshold", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tvdb_search, data([tvdb_show(470_447, "Le safari de Joanie", 2026)]))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Le safari de Joanie", 2022), config)

      assert match.match_confidence < ImportGroups.auto_accept_threshold(),
             "an exact title with a four-year year contradiction scored " <>
               "#{match.match_confidence}, which auto-accepts without a human ever seeing it"
    end

    test "leaves a corroborated year comfortably auto-acceptable", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tvdb_search, data([tvdb_show(277_262, "Cornemuse", 1999)]))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Cornemuse", 1999), config)
      assert match.match_confidence >= ImportGroups.auto_accept_threshold()
    end

    test "counts a year the provider only put in the title", %{bypass: bypass, config: config} do
      # No "year" field and no "first_air_time", so the (2019) suffix is the
      # only year available. Without the fallback the result year is nil, there
      # is no contradiction to find, and this exact title auto-accepts at 0.9
      # against a folder that says 2005.
      stub(bypass, @tvdb_search, data([%{"tvdb_id" => 999_001, "name" => "Cornemuse (2019)"}]))

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Cornemuse", 2005), config)

      assert match.match_confidence < ImportGroups.auto_accept_threshold(),
             "the title's own (2019) contradicts the folder's 2005, but it scored " <>
               "#{match.match_confidence}"
    end

    test "keeps a wrong-year movie below the auto-accept threshold", %{
      bypass: bypass,
      config: config
    } do
      # The Dune cases below pick the right remake with or without the movie
      # penalty, because the correct-year candidate wins on year_match? alone.
      # This is the case that needs it: one candidate, exact title, popular
      # enough that title + popularity alone reach 0.869 and auto-accept a
      # remake as its original.
      stub(bypass, @tmdb_movie_search, results([tmdb_movie(841, "Dune", "1984-12-14", 120.0)]))

      assert {:ok, match} = MetadataMatcher.match_movie(movie("Dune", 2021), config)
      assert match.provider_id == "841"

      assert match.match_confidence < ImportGroups.auto_accept_threshold(),
             "a 37-year year contradiction scored #{match.match_confidence}"
    end
  end

  describe "a movie remake" do
    test "is preferred over the original when the parsed year says so", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tmdb_movie_search, results(@dune))

      assert {:ok, match} = MetadataMatcher.match_movie(movie("Dune", 2021), config)
      assert match.provider_id == "438631"
    end

    test "yields to the original when the parsed year says that instead", %{
      bypass: bypass,
      config: config
    } do
      stub(bypass, @tmdb_movie_search, results(@dune))

      assert {:ok, match} = MetadataMatcher.match_movie(movie("Dune", 1984), config)
      assert match.provider_id == "841"
      assert match.match_confidence >= ImportGroups.auto_accept_threshold()
    end
  end
end
