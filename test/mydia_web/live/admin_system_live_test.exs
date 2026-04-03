defmodule MydiaWeb.AdminSystemLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.Accounts

  setup do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  describe "Authentication" do
    setup do
      start_supervised!(Mydia.Indexers.Health)
      :ok
    end

    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config")
      assert path =~ "/auth"
    end

    test "requires admin role", %{conn: conn, token: _token} do
      {:ok, regular_user} =
        Accounts.create_user(%{
          email: "user@example.com",
          username: "user",
          password_hash: "$2b$12$test",
          role: "user"
        })

      {:ok, regular_token, _claims} = Mydia.Auth.Guardian.encode_and_sign(regular_user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:guardian_default_token, regular_token)
        |> put_req_header("authorization", "Bearer #{regular_token}")

      conn = get(conn, ~p"/admin/config")
      assert redirected_to(conn) == "/"
    end

    test "allows admin access", %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config")
      assert html =~ "Configuration"
    end
  end

  describe "Redirects" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "/admin redirects to /admin/config", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      assert redirected_to(conn) == "/admin/config"
    end

    test "/admin/status redirects to /admin/config", %{conn: conn} do
      conn = get(conn, ~p"/admin/status")
      assert redirected_to(conn) == "/admin/config"
    end
  end

  describe "System Status Tab" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config")
      %{conn: conn, view: view}
    end

    test "renders system status tab by default", %{view: view} do
      assert has_element?(view, ~s{a[class*="tab-active"]}, "Status")
    end

    test "displays system information", %{view: view} do
      assert has_element?(view, "h3", "System")
      assert has_element?(view, ".stat-title", "Version")
      assert has_element?(view, ".stat-title", "Elixir")
      assert has_element?(view, ".stat-title", "Memory")
      assert has_element?(view, ".stat-title", "Uptime")
    end

    test "displays database information", %{view: view} do
      assert has_element?(view, "h3", "Database")
    end

    test "displays database adapter-specific information", %{view: view} do
      html = render(view)

      if Mydia.DB.postgres?() do
        assert html =~ "PostgreSQL"
      else
        assert html =~ "SQLite"
      end
    end
  end

  describe "Tab Navigation" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config")
      %{conn: conn, view: view}
    end

    test "renders tab navigation links", %{view: view} do
      assert has_element?(view, ~s{a[role="tab"]}, "Status")
      assert has_element?(view, ~s{a[role="tab"]}, "Settings")
      assert has_element?(view, ~s{a[role="tab"]}, "Quality")
      assert has_element?(view, ~s{a[role="tab"]}, "Clients")
      assert has_element?(view, ~s{a[role="tab"]}, "Indexers")
      assert has_element?(view, ~s{a[role="tab"]}, "Library")
      assert has_element?(view, ~s{a[role="tab"]}, "Media Servers")
    end

    test "tab links point to correct routes", %{view: view} do
      html = render(view)
      assert html =~ ~s{href="/admin/config/settings"}
      assert html =~ ~s{href="/admin/config/quality"}
      assert html =~ ~s{href="/admin/config/clients"}
      assert html =~ ~s{href="/admin/config/indexers"}
      assert html =~ ~s{href="/admin/config/library-paths"}
      assert html =~ ~s{href="/admin/config/media-servers"}
    end

    test "hides remote access tab when feature is disabled", %{conn: conn} do
      original_features = Application.get_env(:mydia, :features, [])
      Application.put_env(:mydia, :features, Keyword.put(original_features, :remote_access_enabled, false))

      on_exit(fn ->
        Application.put_env(:mydia, :features, original_features)
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/config")

      refute has_element?(view, ~s{a[role="tab"]}, "Remote Access")
    end

    test "shows remote access tab when feature is enabled", %{conn: conn} do
      original_features = Application.get_env(:mydia, :features, [])
      Application.put_env(:mydia, :features, Keyword.put(original_features, :remote_access_enabled, true))

      on_exit(fn ->
        Application.put_env(:mydia, :features, original_features)
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/config")

      assert has_element?(view, ~s{a[role="tab"]}, "Remote Access")
    end
  end
end
