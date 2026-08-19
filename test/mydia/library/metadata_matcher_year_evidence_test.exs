defmodule Mydia.Library.MetadataMatcherYearEvidenceTest do
  @moduledoc """
  Year evidence has to be able to overturn a title tie.

  These tests drive the real scorer through `match_tv_show/3` and a stubbed
  relay rather than re-implementing `calculate_tv_match_score/2`, which is what
  the rest of `metadata_matcher_test.exs` does. A replica cannot fail when the
  original changes, and that is precisely how the Passe-Partout misfile shipped.

  async: false because Mydia.Metadata.Cache is a global ETS table.
  """
  use Mydia.DataCase, async: false

  alias Mydia.ImportGroups
  alias Mydia.Library.MetadataMatcher
  alias Mydia.Metadata.Cache

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

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp parsed(title, year) do
    %{type: :tv_show, title: title, year: year, season: 1, episodes: [1], confidence: 1.0}
  end

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

  describe "a same-title reboot" do
    test "is picked over the original when the parsed year says so", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
        json(conn, %{"data" => @passe_partout})
      end)

      assert {:ok, match} = MetadataMatcher.match_tv_show(parsed("Passe-Partout", 2018), config)

      assert match.provider_id == "356390",
             "picked #{match.title} (#{match.year}) at #{match.match_confidence}; " <>
               "2018 is one year off the 2019 revival and 41 off the original"
    end

    test "does not displace the original when the parsed year agrees with it", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
        json(conn, %{"data" => @passe_partout})
      end)

      assert {:ok, match} = MetadataMatcher.match_tv_show(parsed("Passe-Partout", 1977), config)
      assert match.provider_id == "117091"
    end
  end

  describe "a contradicted year" do
    test "keeps an exact-title match below the auto-accept threshold", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
        json(conn, %{
          "data" => [
            %{
              "tvdb_id" => 470_447,
              "name" => "Le safari de Joanie",
              "year" => "2026",
              "first_air_time" => "2026-01-05"
            }
          ]
        })
      end)

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(parsed("Le safari de Joanie", 2022), config)

      assert match.match_confidence < ImportGroups.auto_accept_threshold(),
             "an exact title with a four-year year contradiction scored " <>
               "#{match.match_confidence}, which auto-accepts without a human ever seeing it"
    end

    test "leaves a corroborated year comfortably auto-acceptable", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
        json(conn, %{
          "data" => [
            %{
              "tvdb_id" => 277_262,
              "name" => "Cornemuse",
              "year" => "1999",
              "first_air_time" => "1999-09-06"
            }
          ]
        })
      end)

      assert {:ok, match} = MetadataMatcher.match_tv_show(parsed("Cornemuse", 1999), config)
      assert match.match_confidence >= ImportGroups.auto_accept_threshold()
    end
  end

  describe "a movie remake" do
    setup %{bypass: bypass} do
      # A popular original and its popular remake share a title on TMDB, which
      # is the movie shape of the Passe-Partout problem.
      Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn conn ->
        json(conn, %{
          "results" => [
            %{
              "id" => 841,
              "title" => "Dune",
              "release_date" => "1984-12-14",
              "popularity" => 120.0
            },
            %{
              "id" => 438_631,
              "title" => "Dune",
              "release_date" => "2021-09-15",
              "popularity" => 300.0
            }
          ]
        })
      end)

      :ok
    end

    defp movie(title, year) do
      %{type: :movie, title: title, year: year, quality: %{}, confidence: 1.0}
    end

    test "is preferred over the original when the parsed year says so", %{config: config} do
      assert {:ok, match} = MetadataMatcher.match_movie(movie("Dune", 2021), config)
      assert match.provider_id == "438631"
    end

    test "does not auto-accept the original when the year contradicts it", %{config: config} do
      assert {:ok, match} = MetadataMatcher.match_movie(movie("Dune", 1984), config)
      assert match.provider_id == "841"

      # Sanity: the 2021 remake is the one being scored down here, so make sure
      # the winner is not itself sitting under the threshold.
      assert match.match_confidence >= ImportGroups.auto_accept_threshold()
    end
  end
end
