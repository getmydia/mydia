defmodule Mydia.Metadata.PeopleTest do
  use ExUnit.Case, async: false

  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.People
  alias Mydia.Metadata.Structs.{Person, PersonCredit, PersonPage, PersonSearchResult}

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp expect_person(bypass, id, cast, assertions \\ fn _ -> :ok end) do
    Bypass.expect_once(bypass, "GET", "/tmdb/person/#{id}", fn conn ->
      assertions.(Plug.Conn.fetch_query_params(conn).query_params)

      json(conn, 200, %{
        "id" => id,
        "name" => "Marisol Vantrell",
        "biography" => "Invented biography.",
        "birthday" => "1979-03-02",
        "place_of_birth" => "Porto Verde",
        "known_for_department" => "Acting",
        "profile_path" => "/face.jpg",
        "combined_credits" => %{"cast" => cast}
      })
    end)
  end

  defp movie(id, title, date, character \\ "Lead") do
    %{
      "id" => id,
      "media_type" => "movie",
      "title" => title,
      "release_date" => date,
      "character" => character,
      "genre_ids" => [18]
    }
  end

  defp tv(id, name, attrs) do
    Map.merge(
      %{
        "id" => id,
        "media_type" => "tv",
        "name" => name,
        "first_air_date" => "2016-05-01",
        "character" => "Guest",
        "episode_count" => 4,
        "genre_ids" => [18]
      },
      attrs
    )
  end

  defp new_id do
    id = System.unique_integer([:positive])
    on_exit(fn -> Cache.delete("person:metadata_relay:#{id}:en-US") end)
    id
  end

  test "parses a person with split, sorted filmography", %{bypass: bypass, config: config} do
    id = new_id()

    expect_person(
      bypass,
      id,
      [
        movie(1, "Older Film", "2015-06-01"),
        movie(2, "Newer Film", "2023-02-10"),
        movie(3, "Untitled Project", ""),
        tv(4, "Harbour Lights", %{})
      ],
      fn query ->
        assert query["append_to_response"] == "combined_credits"
        assert query["language"] == "en-US"
      end
    )

    assert {:ok, %Person{} = person} = People.fetch_person_cached(config, id)
    assert person.birthday == ~D[1979-03-02]
    assert person.name == "Marisol Vantrell"

    assert Enum.map(person.movie_credits, & &1.title) == [
             "Newer Film",
             "Older Film",
             "Untitled Project"
           ]

    assert [%PersonCredit{media_type: :tv_show, title: "Harbour Lights", episode_count: 4}] =
             person.tv_credits
  end

  test "collapses a title repeated per character into one credit with joined characters",
       %{bypass: bypass, config: config} do
    id = new_id()

    expect_person(bypass, id, [
      movie(9, "Twin Tides", "2020-01-01", "Inés"),
      movie(9, "Twin Tides", "2020-01-01", "Inés (voice)")
    ])

    assert {:ok, %Person{movie_credits: [credit]}} = People.fetch_person_cached(config, id)
    assert credit.character == "Inés / Inés (voice)"
  end

  test "a character repeated after another is joined once", %{bypass: bypass, config: config} do
    id = new_id()

    expect_person(bypass, id, [
      movie(9, "Twin Tides", "2020-01-01", "Inés"),
      movie(9, "Twin Tides", "2020-01-01", "Marisol"),
      movie(9, "Twin Tides", "2020-01-01", "Inés")
    ])

    assert {:ok, %Person{movie_credits: [credit]}} = People.fetch_person_cached(config, id)
    assert credit.character == "Inés / Marisol"
  end

  test "drops talk and news TV credits and untitled entries", %{bypass: bypass, config: config} do
    id = new_id()

    expect_person(bypass, id, [
      tv(10, "Late Hour", %{"genre_ids" => [10767]}),
      tv(11, "Daily Bulletin", %{"genre_ids" => [10763]}),
      tv(12, "x", %{}) |> Map.delete("name"),
      tv(13, "Keeper", %{})
    ])

    assert {:ok, %Person{tv_credits: [%{title: "Keeper"}]}} =
             People.fetch_person_cached(config, id)
  end

  test "a movie and a show with the same TMDB id stay separate", %{bypass: bypass, config: config} do
    id = new_id()

    expect_person(bypass, id, [
      movie(500, "Same Id Film", "2018-01-01"),
      tv(500, "Same Id Show", %{})
    ])

    assert {:ok, person} = People.fetch_person_cached(config, id)
    assert [%{tmdb_id: 500, title: "Same Id Film"}] = person.movie_credits
    assert [%{tmdb_id: 500, title: "Same Id Show"}] = person.tv_credits
  end

  test "search parses known_for titles", %{bypass: bypass, config: config} do
    query = "vantrell#{System.unique_integer([:positive])}"
    on_exit(fn -> Cache.delete("person_search:metadata_relay:#{query}:en-US:1") end)

    Bypass.expect_once(bypass, "GET", "/tmdb/person/search", fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["query"] == query
      assert params["include_adult"] == "false"

      json(conn, 200, %{
        "results" => [
          %{
            "id" => 31,
            "name" => "Marisol Vantrell",
            "profile_path" => "/face.jpg",
            "known_for_department" => "Acting",
            "known_for" => [
              %{"media_type" => "movie", "title" => "The Salt Ledger"},
              %{"media_type" => "tv", "name" => "Harbour Lights"}
            ]
          }
        ]
      })
    end)

    assert {:ok, %PersonPage{results: [%PersonSearchResult{} = result], page: 1, total_pages: 1}} =
             People.search_people_cached(config, query)

    assert result.tmdb_id == 31
    assert result.known_for == ["The Salt Ledger", "Harbour Lights"]
  end

  test "search passes page and reads total_pages", %{bypass: bypass, config: config} do
    query = "quillon#{System.unique_integer([:positive])}"
    on_exit(fn -> Cache.delete("person_search:metadata_relay:#{query}:en-US:2") end)

    Bypass.expect_once(bypass, "GET", "/tmdb/person/search", fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params["page"] == "2"

      json(conn, 200, %{
        "page" => 2,
        "total_pages" => 5,
        "results" => [%{"id" => 32, "name" => "Teodor Quillon"}]
      })
    end)

    assert {:ok, %PersonPage{page: 2, total_pages: 5} = page} =
             People.search_people_cached(config, query, page: 2)

    assert PersonPage.more?(page)
  end

  test "adult-flagged people are dropped", %{bypass: bypass, config: config} do
    on_exit(fn -> Cache.delete("person_popular:metadata_relay:en-US:9") end)
    Cache.delete("person_popular:metadata_relay:en-US:9")

    Bypass.expect_once(bypass, "GET", "/tmdb/person/popular", fn conn ->
      json(conn, 200, %{
        "page" => 9,
        "total_pages" => 9,
        "results" => [
          %{"id" => 40, "name" => "Ottilie Brand", "adult" => true},
          %{"id" => 41, "name" => "Casimir Vale", "adult" => false}
        ]
      })
    end)

    assert {:ok, %PersonPage{results: [%PersonSearchResult{tmdb_id: 41}]}} =
             People.popular_people_cached(config, page: 9)
  end

  test "popular people parse like search results", %{bypass: bypass, config: config} do
    on_exit(fn -> Cache.delete("person_popular:metadata_relay:en-US:1") end)
    Cache.delete("person_popular:metadata_relay:en-US:1")

    Bypass.expect_once(bypass, "GET", "/tmdb/person/popular", fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["page"] == "1"
      assert params["language"] == "en-US"

      json(conn, 200, %{
        "page" => 1,
        "total_pages" => 500,
        "results" => [
          %{
            "id" => 33,
            "name" => "Wren Abernathy",
            "known_for" => [%{"media_type" => "movie", "title" => "Copper Tide"}]
          }
        ]
      })
    end)

    assert {:ok, %PersonPage{results: [result], total_pages: 500}} =
             People.popular_people_cached(config)

    assert result.tmdb_id == 33
    assert result.known_for == ["Copper Tide"]
  end

  test "a missing total_pages ends paging", %{bypass: bypass, config: config} do
    on_exit(fn -> Cache.delete("person_popular:metadata_relay:en-US:3") end)
    Cache.delete("person_popular:metadata_relay:en-US:3")

    Bypass.expect_once(bypass, "GET", "/tmdb/person/popular", fn conn ->
      json(conn, 200, %{"results" => []})
    end)

    assert {:ok, %PersonPage{page: 3, total_pages: 3} = page} =
             People.popular_people_cached(config, page: 3)

    refute PersonPage.more?(page)
  end

  test "popular 404 is an error and is not cached", %{bypass: bypass, config: config} do
    Cache.delete("person_popular:metadata_relay:en-US:7")
    counter = :counters.new(1, [])

    Bypass.expect(bypass, "GET", "/tmdb/person/popular", fn conn ->
      :counters.add(counter, 1, 1)
      json(conn, 404, %{})
    end)

    assert {:error, _} = People.popular_people_cached(config, page: 7)
    assert {:error, _} = People.popular_people_cached(config, page: 7)
    assert :counters.get(counter, 1) == 2
  end

  test "relay 404 is an error and is not cached", %{bypass: bypass, config: config} do
    id = new_id()
    counter = :counters.new(1, [])

    Bypass.expect(bypass, "GET", "/tmdb/person/#{id}", fn conn ->
      :counters.add(counter, 1, 1)
      json(conn, 404, %{})
    end)

    assert {:error, _} = People.fetch_person_cached(config, id)
    assert {:error, _} = People.fetch_person_cached(config, id)
    assert :counters.get(counter, 1) == 2
  end

  test "non-relay config is rejected" do
    assert {:error, _} = People.fetch_person_cached(%{type: :tvdb}, 1)
    assert {:error, _} = People.search_people_cached(%{type: :tvdb}, "x")
    assert {:error, _} = People.popular_people_cached(%{type: :tvdb})
  end

  test "to_search_result builds a TMDB SearchResult" do
    credit = %PersonCredit{
      tmdb_id: 77,
      media_type: :tv_show,
      title: "Harbour Lights",
      year: 2016,
      date: ~D[2016-05-01],
      poster_path: "/p.jpg",
      backdrop_path: "/b.jpg",
      overview: "o",
      genre_ids: [18],
      origin_country: ["PT"],
      original_language: "pt",
      vote_average: 7.5
    }

    result = PersonCredit.to_search_result(credit)
    assert result.provider == :tmdb
    assert result.provider_id == "77"
    assert result.media_type == :tv_show
    assert result.title == "Harbour Lights"
    assert result.year == 2016
    assert result.first_air_date == "2016-05-01"
    assert result.release_date == nil
    assert result.genre_ids == [18]
    assert result.origin_country == ["PT"]
    assert result.original_language == "pt"
    assert result.vote_average == 7.5

    movie = PersonCredit.to_search_result(%{credit | media_type: :movie})
    assert movie.release_date == "2016-05-01"
    assert movie.first_air_date == nil
  end
end
