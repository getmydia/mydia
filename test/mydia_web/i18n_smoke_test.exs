defmodule MydiaWeb.I18nSmokeTest do
  @moduledoc """
  Each converted page renders its drafted Spanish text.

  The expected strings are hardcoded from `priv/gettext/es/LC_MESSAGES/default.po`
  on purpose: a test that looked them up through Gettext would still pass if a
  page stopped calling `gettext/1`.
  """

  # async: false, as for the dashboard and discover tests: both warm the shared
  # metadata ETS cache, and the LiveView process needs the shared sandbox to see
  # the fixture rows on PostgreSQL.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  setup %{conn: conn} do
    # Dashboard and discover load trending rails and genres on connected mount;
    # warm the cache so neither reaches the network.
    warm_genre_cache(:movie, [%{"id" => 28, "name" => "Action"}])
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    user = admin_user_fixture()
    %{conn: conn |> log_in_user(user) |> put_req_header("accept-language", "es")}
  end

  defp text(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  test "media library index", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/movies")
    assert text(html, "#section-heading") == "Películas"
  end

  test "media detail page", %{conn: conn} do
    movie = media_item_fixture(%{title: "The Lantern Orchard"})
    {:ok, _view, html} = live(conn, ~p"/movies/#{movie.id}")
    assert text(html, "#movie-monitored-toggle") == "Monitorizado"
  end

  test "collections index", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/collections")
    assert text(html, "#browse-presets-button") == "Explorar preajustes"
  end

  test "home dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert text(html, "#edit-home-btn") == "Editar inicio"
  end

  test "downloads", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/downloads")
    assert text(html, "#downloads-view-active") == "Activa"
  end

  test "activity", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/activity")
    assert text(html, "#activity-heading") == "Feed de actividad"
  end

  test "calendar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/calendar")
    assert text(html, "#calendar-heading") == "Calendario"
  end

  test "my requests", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/requests")
    assert text(html, "#my-requests-heading") == "Mis solicitudes"
  end

  test "search", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/search")
    assert text(html, "#search-heading") == "Buscar contenido"
  end

  test "discover", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/discover")
    assert text(html, "#discover-country-settings-button") == "Tu país"
  end

  test "import", %{conn: conn} do
    # The review query needs at least one library to scope to.
    library_path_fixture(%{type: "movies"})
    {:ok, _view, html} = live(conn, ~p"/import")
    assert text(html, "#import-heading") == "Importar"
  end

  test "devices", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices")
    assert text(html, "#confirm-revoke") == "Revocar"
  end

  test "integrations", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/integrations")
    assert text(html, "#integrations-browse-plugins") == "Explorar complementos"
  end
end
