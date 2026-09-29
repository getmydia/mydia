defmodule Mydia.Library.MetadataMatcherLocalTest do
  @moduledoc """
  The local-library lookup `MetadataMatcher` runs before any provider search.

  It used to accept any library item scoring 0.70 on `Text.title_similarity/2`,
  which filed one show's episodes under an unrelated show whose title merely
  shared letters or a substring (#957). Each refusal test below asserts that the
  old metric would have accepted the pair, so it keeps proving something if
  `title_similarity/2` changes.

  async: false because Mydia.Metadata.Cache is a global ETS table.
  """
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Library.MetadataMatcher
  alias Mydia.Library.Text
  alias Mydia.Metadata.Cache

  @tvdb_search "/tvdb/search"
  @tmdb_movie_search "/tmdb/movies/search"

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

  defp tvdb_show(id, name, year) do
    %{
      "tvdb_id" => id,
      "name" => name,
      "year" => to_string(year),
      "first_air_time" => "#{year}-01-01"
    }
  end

  defp tv(title, year, season \\ 1, episodes \\ [1]) do
    %{
      type: :tv_show,
      title: title,
      year: year,
      season: season,
      episodes: episodes,
      confidence: 1.0
    }
  end

  defp movie(title, year),
    do: %{type: :movie, title: title, year: year, quality: %{}, confidence: 1.0}

  defp assert_old_metric_accepted!(a, b) do
    assert Text.title_similarity(a, b) >= 0.70,
           "precondition: #{a} vs #{b} must clear the old 0.70 bar, or this test proves nothing"
  end

  describe "local TV match" do
    test "matches a library show whose clean-title key is identical", %{config: config} do
      show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Moth-Man: Far From Shore",
          year: 2019,
          tvdb_id: 900
        })

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Moth Man Far From Shore", 2019), config)

      assert match.from_local_db
      assert match.provider_id == "900"
      assert match.title == show.title
    end

    test "matches through a provider year suffix on the library title", %{config: config} do
      media_item_fixture(%{type: "tv_show", title: "Quillon (2021)", year: 2021, tvdb_id: 901})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Quillon", 2021), config)
      assert match.from_local_db
      assert match.provider_id == "901"
    end

    test "refuses a title that is only a substring of a library show", %{
      bypass: bypass,
      config: config
    } do
      assert_old_metric_accepted!("Vardo", "The Vardolian")
      media_item_fixture(%{type: "tv_show", title: "The Vardolian", year: 2022, tvdb_id: 902})
      stub(bypass, @tvdb_search, %{"data" => [tvdb_show(501, "Vardo", 2022)]})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Vardo", 2022), config)
      refute match.from_local_db
      assert match.provider_id == "501"
    end

    test "refuses a near-spelling of a library show", %{bypass: bypass, config: config} do
      assert_old_metric_accepted!("Harbor Nights", "Harbor Lights")
      media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013, tvdb_id: 903})
      stub(bypass, @tvdb_search, %{"data" => [tvdb_show(502, "Harbor Nights", 2013)]})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Harbor Nights", 2013), config)
      refute match.from_local_db
      assert match.provider_id == "502"
    end

    test "leaves two same-key shows with no year tie-break to the provider search", %{
      bypass: bypass,
      config: config
    } do
      media_item_fixture(%{type: "tv_show", title: "Quillon", year: 2004, tvdb_id: 904})
      media_item_fixture(%{type: "tv_show", title: "Quillon", year: 2021, tvdb_id: 905})
      stub(bypass, @tvdb_search, %{"data" => [tvdb_show(905, "Quillon", 2021)]})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Quillon", nil), config)
      refute match.from_local_db
    end

    test "settles two same-key shows by exact year", %{config: config} do
      media_item_fixture(%{type: "tv_show", title: "Quillon", year: 2020, tvdb_id: 904})
      media_item_fixture(%{type: "tv_show", title: "Quillon", year: 2021, tvdb_id: 905})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Quillon", 2021), config)
      assert match.from_local_db
      assert match.provider_id == "905"
    end

    test "falls through to the provider when two same-key shows are both year-compatible but neither is exact",
         %{bypass: bypass, config: config} do
      media_item_fixture(%{type: "tv_show", title: "Quillon", year: 2020, tvdb_id: 904})
      media_item_fixture(%{type: "tv_show", title: "Quillon", year: 2022, tvdb_id: 906})
      stub(bypass, @tvdb_search, %{"data" => [tvdb_show(906, "Quillon", 2022)]})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Quillon", 2021), config)
      refute match.from_local_db
    end

    test "matches a library show through its original title", %{bypass: bypass, config: config} do
      media_item_fixture(%{
        type: "tv_show",
        title: "The Vardolian",
        original_title: "Vardoriyan",
        year: 2022,
        tvdb_id: 950
      })

      stub(bypass, @tvdb_search, %{"data" => []})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Vardoriyan", 2022), config)
      assert match.from_local_db
      assert match.provider_id == "950"
    end

    test "a near-miss on an alternate title still falls through to the provider", %{
      bypass: bypass,
      config: config
    } do
      media_item_fixture(%{
        type: "tv_show",
        title: "The Vardolian",
        original_title: "Vardoriyan",
        year: 2022,
        tvdb_id: 951
      })

      stub(bypass, @tvdb_search, %{"data" => [tvdb_show(952, "Vardoriya", 2022)]})

      assert {:ok, match} = MetadataMatcher.match_tv_show(tv("Vardoriya", 2022), config)
      refute match.from_local_db
      assert match.provider_id == "952"
    end
  end

  describe "local TV match episode check" do
    setup do
      show =
        media_item_fixture(%{type: "tv_show", title: "Harbor Lights", year: 2013, tvdb_id: 920})

      %{show: show}
    end

    test "keeps full confidence when the parsed episode exists", %{show: show, config: config} do
      episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Harbor Lights", 2013, 2, [3]), config)

      assert match.match_confidence == 0.95
    end

    test "drops below auto-accept when the parsed episode is missing", %{
      show: show,
      config: config
    } do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Harbor Lights", 2013, 3, [10]), config)

      assert match.from_local_db
      assert match.match_confidence < Mydia.ImportCandidates.auto_accept_threshold()
    end

    test "drops below auto-accept when one episode of a multi-episode file is missing", %{
      show: show,
      config: config
    } do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Harbor Lights", 2013, 1, [1, 2]), config)

      assert match.match_confidence < Mydia.ImportCandidates.auto_accept_threshold()
    end

    test "skips the check for a show with no episode rows", %{config: config} do
      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Harbor Lights", 2013, 3, [10]), config)

      assert match.match_confidence == 0.95
    end

    test "skips the check for a parse with no episode number", %{show: show, config: config} do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      assert {:ok, match} =
               MetadataMatcher.match_tv_show(tv("Harbor Lights", 2013, 4, []), config)

      assert match.match_confidence == 0.95
    end
  end

  describe "local movie match" do
    test "refuses a year-adjacent movie that only contains the title", %{
      bypass: bypass,
      config: config
    } do
      assert_old_metric_accepted!("The Lantern", "The Lanternboy")
      media_item_fixture(%{type: "movie", title: "The Lanternboy", year: 1998, tmdb_id: 910})

      stub(bypass, @tmdb_movie_search, %{
        "results" => [
          %{
            "id" => 601,
            "title" => "The Lantern",
            "release_date" => "1999-03-31",
            "popularity" => 50.0
          }
        ]
      })

      assert {:ok, match} = MetadataMatcher.match_movie(movie("The Lantern", 1999), config)
      refute match.from_local_db
      assert match.provider_id == "601"
    end

    test "matches a movie whose key is identical and year is one off", %{config: config} do
      media_item_fixture(%{type: "movie", title: "Glass Harbor II", year: 2012, tmdb_id: 911})

      assert {:ok, match} = MetadataMatcher.match_movie(movie("Glass Harbor 2", 2011), config)
      assert match.from_local_db
      assert match.provider_id == "911"
    end
  end
end
