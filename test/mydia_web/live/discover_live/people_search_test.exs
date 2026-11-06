defmodule MydiaWeb.DiscoverLive.PeopleSearchTest do
  @moduledoc """
  The People scope of Discover's search: a Titles / People choice shown while
  a query is active, with people results that open the person popup.

  Every relay route is served by one Bypass, pointed at with the global relay
  URL, so this file cannot run async.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  @query "ventura"
  @person_id 501

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])
    warm_movie_search_cache(@query, [], [])

    language = Metadata.default_relay_config().options.language
    search_key = "person_search:metadata_relay:#{@query}:#{language}"
    person_key = "person:metadata_relay:#{@person_id}:#{language}"
    Cache.delete(search_key)
    Cache.delete(person_key)

    on_exit(fn ->
      Cache.delete(search_key)
      Cache.delete(person_key)
    end)

    %{conn: log_in_user(conn, create_admin_user()), bypass: point_relay_at_bypass()}
  end

  test "the scope control only shows while a query is active", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")
    refute has_element?(view, "#discover-search-scope")

    view |> form("#discover-search-form", %{"q" => @query}) |> render_submit()

    assert has_element?(view, "#discover-search-scope")
    assert has_element?(view, "#discover-scope-titles.btn-active")
  end

  test "choosing People shows people instead of titles", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=#{@query}")

    view |> element("#discover-scope-people") |> render_click()

    assert_patched(view, ~p"/discover?q=#{@query}&scope=people&type=movie")
    assert has_element?(view, "#discover-scope-people.btn-active")
    assert has_element?(view, "#discover-people-results")
    assert has_element?(view, "#discover-person-#{@person_id}", "Odalys Ventura")
    assert has_element?(view, "#discover-person-#{@person_id}", "Glass Orchard, Tidewater Bureau")

    refute has_element?(view, "#discover-grid")
    refute has_element?(view, "[role=tablist]")
    refute has_element?(view, "#discover-filter-form")

    # Grid density and "Hide in library" act on title results only.
    refute has_element?(view, "#discover-density-toggle")
    refute has_element?(view, "#discover-hide-owned")
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

    {:ok, view, _html} = live(conn, ~p"/discover?q=#{@query}&scope=people")

    assert has_element?(view, "#discover-person-#{@person_id}", "Directing")
  end

  test "clicking a person opens the person popup", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

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

    {:ok, view, _html} = live(conn, ~p"/discover?q=#{@query}&scope=people")

    view |> element("#discover-person-#{@person_id}") |> render_click()
    render_async(view)

    assert has_element?(view, "#person-modal[open]")
    assert has_element?(view, "#person-modal-name", "Odalys Ventura")
  end

  test "clearing the search drops the scope", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=#{@query}&scope=people")

    view |> element("#discover-search-clear") |> render_click()

    assert_patched(view, ~p"/discover?type=movie")
    refute has_element?(view, "#discover-search-scope")
    refute has_element?(view, "#discover-people-results")
    assert has_element?(view, "[role=tablist]")
  end

  test "a new query keeps the People scope", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=#{@query}&scope=people")

    view |> form("#discover-search-form", %{"q" => @query}) |> render_submit()

    assert_patched(view, ~p"/discover?q=#{@query}&scope=people&type=movie")
  end

  test "choosing Titles goes back to the title results", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=#{@query}&scope=people")

    view |> element("#discover-scope-titles") |> render_click()

    assert_patched(view, ~p"/discover?q=#{@query}&type=movie")
    refute has_element?(view, "#discover-people-results")
    assert has_element?(view, "#discover-density-toggle")
    assert has_element?(view, "#discover-hide-owned")
  end

  test "loading a people search directly renders people", %{conn: conn, bypass: bypass} do
    stub_search(bypass)

    {:ok, view, _html} = live(conn, ~p"/discover?q=#{@query}&scope=people")

    assert has_element?(view, "#discover-scope-people.btn-active")
    assert has_element?(view, "#discover-person-#{@person_id}")
  end

  test "scope=people without a query renders normal Discover", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover?scope=people")

    refute has_element?(view, "#discover-search-scope")
    refute has_element?(view, "#discover-people-results")
    assert has_element?(view, "[role=tablist]")
  end

  @tag :capture_log
  test "a relay failure renders an inline error", %{conn: conn, bypass: bypass} do
    Bypass.stub(bypass, "GET", "/tmdb/person/search", fn conn ->
      json(conn, 500, %{"error" => "boom"})
    end)

    {:ok, view, _html} = live(conn, ~p"/discover?q=#{@query}&scope=people")

    assert has_element?(view, "#discover-people-error")
    refute has_element?(view, "#discover-people-results")
    assert has_element?(view, "#discover-search-scope")
  end

  defp stub_search(bypass, results \\ nil) do
    results =
      results ||
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

    Bypass.stub(bypass, "GET", "/tmdb/person/search", fn conn ->
      json(conn, 200, %{"page" => 1, "results" => results, "total_pages" => 1})
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
