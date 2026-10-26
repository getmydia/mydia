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

  # Spanish page labels as `MydiaWeb.AdminNav.page_label/1` renders them, hardcoded
  # for the reason in the moduledoc. The registry test below fails when a page is
  # added to `AdminNav` without a row here.
  @admin_page_labels %{
    quality: "Calidad",
    custom_formats: "Formatos personalizados",
    clients: "Clientes",
    indexers: "Indexadores",
    library_paths: "Biblioteca",
    path_mappings: "Asignaciones de rutas",
    subtitle_providers: "Proveedores de subtítulos",
    media_servers: "Servidores multimedia",
    storage_backends: "Almacenamiento",
    requests: "Solicitudes",
    jobs: "Tareas en segundo plano",
    release_blacklist: "Lista de bloqueo de lanzamientos",
    duplicates: "Duplicados",
    trash: "Papelera",
    status: "Estado",
    dashboard: "Panel",
    settings: "Ajustes",
    users: "Usuarios",
    api_keys: "Claves de API",
    remote_access: "Acceso remoto",
    plugins: "Complementos"
  }

  @admin_hub_labels %{
    configuration: "Configuración",
    administration: "Administración",
    system: "Sistema"
  }

  describe "admin pages" do
    setup do
      # Background Jobs reads the Oban crontab, and Oban is not started in test.
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

      # Remote Access looks up the public IP over HTTP unless told not to.
      original_direct_urls = Application.get_env(:mydia, :direct_urls, [])
      Application.put_env(:mydia, :direct_urls, public_ip_enabled: false)
      on_exit(fn -> Application.put_env(:mydia, :direct_urls, original_direct_urls) end)

      :ok
    end

    test "every AdminNav page has an expected label here" do
      assert Enum.sort(Map.keys(@admin_page_labels)) == Enum.sort(MydiaWeb.AdminNav.keys())
    end

    for {key, label} <- @admin_page_labels do
      test "admin #{key}", %{conn: conn} do
        page = MydiaWeb.AdminNav.fetch!(unquote(key))
        {:ok, _view, html} = live(conn, page.path)

        # The hub is the page header; the page itself is the active tab.
        assert text(html, "#admin-page-title") == @admin_hub_labels[page.hub]
        assert text(html, "#admin-tab-#{unquote(key)}") =~ unquote(label)
      end
    end

    test "the sidebar names the three hubs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/trash")

      assert text(html, "#admin-nav-configuration") == "Configuración"
      assert text(html, "#admin-nav-administration") == "Administración"
      assert text(html, "#admin-nav-system") == "Sistema"
    end
  end
end
