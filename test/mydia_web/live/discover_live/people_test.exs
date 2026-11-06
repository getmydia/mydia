defmodule MydiaWeb.DiscoverLive.PeopleTest do
  @moduledoc """
  Discover's People type (`?type=person`): a popular-people grid with no
  query, people search results with one, both paging in on scroll, and a
  person that opens the person popup.

  Every relay route is served by one Bypass, pointed at with the global relay
  URL, so this file cannot run async.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias MydiaWeb.DiscoverLive.UrlParams

  @query "ventura"
  @other_query "okafor"
  @person_id 501

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])
    warm_movie_search_cache(@query, [], [])

    language = Metadata.default_relay_config().options.language

    keys =
      for(page <- 1..3, do: "person_popular:metadata_relay:#{language}:#{page}") ++
        for(
          query <- [@query, @other_query],
          page <- 1..2,
          do: "person_search:metadata_relay:#{query}:#{language}:#{page}"
        ) ++ ["person:metadata_relay:#{@person_id}:#{language}"]

    Enum.each(keys, &Cache.delete/1)
    on_exit(fn -> Enum.each(keys, &Cache.delete/1) end)

    %{conn: log_in_user(conn, create_admin_user()), bypass: point_relay_at_bypass()}
  end

  test "person parses as a media type and unknown types still fall back to movies" do
    assert UrlParams.parse_media_type("person") == :person
    assert UrlParams.parse_media_type("bogus") == :movie
  end

  test "People is a third media type showing popular people", %{conn: conn, bypass: bypass} do
    stub_popular(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover")

    view |> element("#discover-type-person") |> render_click()

    assert_patched(view, ~p"/discover?type=person")
    render_async(view)
    assert has_element?(view, "#discover-people-results")
    assert has_element?(view, "#discover-person-#{@person_id}", "Odalys Ventura")
    assert has_element?(view, "#discover-person-#{@person_id}", "Glass Orchard, Tidewater Bureau")
  end

  test "People hides the title-only controls", %{conn: conn, bypass: bypass} do
    stub_popular(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    refute has_element?(view, "[role=tablist]")
    refute has_element?(view, "#discover-filter-form")
    refute has_element?(view, "#discover-density-toggle")
    refute has_element?(view, "#discover-hide-owned")
    refute has_element?(view, "#discover-search-scope")
    assert has_element?(view, "#discover-search-input[placeholder='Search people']")
  end

  test "searching on People shows matching people", %{conn: conn, bypass: bypass} do
    stub_popular(bypass)
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    view |> form("#discover-search-form", %{"q" => @query}) |> render_submit()

    assert_patched(view, ~p"/discover?q=#{@query}&type=person")
    render_async(view)
    assert has_element?(view, "#discover-search-chip")
    assert has_element?(view, "#discover-person-#{@person_id}", "Odalys Ventura")
  end

  test "load_more appends the next page and stops at the last", %{conn: conn, bypass: bypass} do
    stub_popular(bypass, %{
      "1" => page(1, 2, [person(@person_id, "Odalys Ventura")]),
      "2" => page(2, 2, [person(502, "Bram Okafor")])
    })

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)
    assert has_element?(view, "#discover-people-load-more[data-has-more=true]")

    render_hook(view, "load_more", %{})
    render_async(view)

    assert has_element?(view, "#discover-person-#{@person_id}")
    assert has_element?(view, "#discover-person-502")
    assert has_element?(view, "#discover-people-load-more[data-has-more=false]")
  end

  test "load_more drops people already shown", %{conn: conn, bypass: bypass} do
    stub_popular(bypass, %{
      "1" => page(1, 2, [person(@person_id, "Odalys Ventura")]),
      "2" => page(2, 2, [person(@person_id, "Odalys Ventura"), person(503, "Iva Lund")])
    })

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    render_hook(view, "load_more", %{})
    render_async(view)

    doc = view |> render() |> LazyHTML.from_fragment()
    assert doc |> LazyHTML.query("#discover-person-#{@person_id}") |> Enum.count() == 1
    assert has_element?(view, "#discover-person-503")
  end

  test "a people result after switching to Movies is ignored", %{conn: conn, bypass: bypass} do
    test_pid = self()

    Bypass.stub(bypass, "GET", "/tmdb/person/popular", fn conn ->
      send(test_pid, {:popular_waiting, self()})

      receive do
        :release -> json(conn, 200, page(1, 1, default_results()))
      after
        5_000 -> json(conn, 504, %{})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    assert_receive {:popular_waiting, handler}, 2_000

    view |> element("#discover-type-movie") |> render_click()
    assert_patched(view, ~p"/discover?type=movie")

    send(handler, :release)
    render_async(view)

    refute has_element?(view, "#discover-people-results")
    assert has_element?(view, "[role=tablist]")
  end

  @tag :capture_log
  test "a failed first page offers Try again, which reloads", %{conn: conn, bypass: bypass} do
    # 0 fails, 1 answers. A 404, not a 500: Req retries a 500 after a delay.
    relay_up = :counters.new(1, [])

    Bypass.stub(bypass, "GET", "/tmdb/person/popular", fn conn ->
      if :counters.get(relay_up, 1) == 0,
        do: json(conn, 404, %{"error" => "boom"}),
        else: json(conn, 200, page(1, 1, default_results()))
    end)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    assert has_element?(view, "#discover-people-error")
    refute has_element?(view, "#discover-people-results")

    :counters.add(relay_up, 1, 1)
    view |> element("#discover-people-retry") |> render_click()
    render_async(view)

    refute has_element?(view, "#discover-people-error")
    assert has_element?(view, "#discover-person-#{@person_id}")
  end

  @tag :capture_log
  test "a failed later page keeps the people shown and offers Retry", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.stub(bypass, "GET", "/tmdb/person/popular", fn conn ->
      case Plug.Conn.fetch_query_params(conn).query_params["page"] do
        "1" -> json(conn, 200, page(1, 2, default_results()))
        _ -> json(conn, 404, %{"error" => "boom"})
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    render_hook(view, "load_more", %{})
    render_async(view)

    assert has_element?(view, "#discover-person-#{@person_id}")
    assert has_element?(view, "#discover-people-load-more-retry")
    refute has_element?(view, "#discover-people-error")
  end

  test "a beta.3 scope link lands on the People type", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    # A patch during mount is followed inside live/2, so the landed state is
    # what can be asserted, not the patch itself.
    {:ok, view, _html} = live(conn, ~p"/discover?q=#{@query}&scope=people")
    render_async(view)

    assert has_element?(view, "#discover-type-person[aria-pressed=true]")
    assert has_element?(view, "#discover-search-input[value=#{@query}]")
    assert has_element?(view, "#discover-person-#{@person_id}")
  end

  test "a person with no known-for titles shows their department", %{
    conn: conn,
    bypass: bypass
  } do
    stub_search(bypass, [
      %{
        "id" => @person_id,
        "name" => "Odalys Ventura",
        "profile_path" => nil,
        "known_for_department" => "Directing",
        "known_for" => []
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/discover?type=person&q=#{@query}")
    render_async(view)

    assert has_element?(view, "#discover-person-#{@person_id}", "Directing")
  end

  test "a restricted viewer gets the department instead of known-for titles", %{
    bypass: bypass
  } do
    stub_popular(bypass)
    user = restricted_user_fixture(%{max_content_age: 12})
    conn = log_in_user(build_conn(), user)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    assert has_element?(view, "#discover-person-#{@person_id}", "Acting")
    refute has_element?(view, "#discover-person-#{@person_id}", "Glass Orchard")
  end

  test "clicking a person opens the person popup", %{conn: conn, bypass: bypass} do
    stub_popular(bypass)

    Bypass.stub(bypass, "GET", "/tmdb/person/#{@person_id}", fn conn ->
      json(conn, 200, %{
        "id" => @person_id,
        "name" => "Odalys Ventura",
        "biography" => "An invented performer.",
        "known_for_department" => "Acting",
        "profile_path" => nil,
        "combined_credits" => %{"cast" => []}
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person")
    render_async(view)

    view |> element("#discover-person-#{@person_id}") |> render_click()
    render_async(view)

    assert has_element?(view, "#person-modal[open]")
    assert has_element?(view, "#person-modal-name", "Odalys Ventura")
  end

  test "a new query replaces the results", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person&q=#{@query}")
    render_async(view)
    assert has_element?(view, "#discover-person-#{@person_id}")

    view |> form("#discover-search-form", %{"q" => @other_query}) |> render_submit()

    assert_patched(view, ~p"/discover?q=#{@other_query}&type=person")
    render_async(view)
    assert has_element?(view, "#discover-person-502", "Bram Okafor")
    refute has_element?(view, "#discover-person-#{@person_id}")
  end

  test "clearing the search goes back to popular people", %{conn: conn, bypass: bypass} do
    stub_search(bypass, [person(502, "Bram Okafor")])
    stub_popular(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=person&q=#{@query}")
    render_async(view)
    assert has_element?(view, "#discover-person-502")

    view |> element("#discover-search-clear") |> render_click()

    assert_patched(view, ~p"/discover?type=person")
    render_async(view)
    assert has_element?(view, "#discover-person-#{@person_id}")
    refute has_element?(view, "#discover-person-502")
  end

  defp stub_popular(bypass, pages \\ %{"1" => page(1, 1, default_results())}) do
    Bypass.stub(bypass, "GET", "/tmdb/person/popular", fn conn ->
      requested = Plug.Conn.fetch_query_params(conn).query_params["page"] || "1"
      json(conn, 200, Map.fetch!(pages, requested))
    end)
  end

  defp stub_search(bypass, results \\ nil) do
    Bypass.stub(bypass, "GET", "/tmdb/person/search", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["page"] == "1"

      results =
        cond do
          results -> results
          conn.query_params["query"] == @other_query -> [person(502, "Bram Okafor")]
          true -> default_results()
        end

      json(conn, 200, page(1, 1, results))
    end)
  end

  defp page(number, total, results),
    do: %{"page" => number, "total_pages" => total, "results" => results}

  defp person(id, name) do
    %{
      "id" => id,
      "name" => name,
      "profile_path" => nil,
      "known_for_department" => "Acting",
      "known_for" => []
    }
  end

  defp default_results do
    [
      %{
        "id" => @person_id,
        "name" => "Odalys Ventura",
        "profile_path" => "/odalys.jpg",
        "known_for_department" => "Acting",
        "known_for" => [
          %{"media_type" => "movie", "title" => "Glass Orchard"},
          %{"media_type" => "tv", "name" => "Tidewater Bureau"}
        ]
      }
    ]
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
