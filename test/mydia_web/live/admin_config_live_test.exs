defmodule MydiaWeb.AdminConfigLiveTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  alias Mydia.{Accounts, Settings}

  setup do
    # Create an admin user for testing
    {:ok, user} =
      Accounts.create_user(%{
        email: "admin@example.com",
        username: "admin",
        password_hash: "$2b$12$test",
        role: :admin
      })

    # Generate JWT token for the user
    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  describe "Index - Authentication" do
    test "requires authentication", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config")
      # Should redirect to login
      assert path =~ "/auth"
    end

    test "requires admin role", %{conn: conn, token: token} do
      # Create a regular user (non-admin)
      {:ok, regular_user} =
        Accounts.create_user(%{
          email: "user@example.com",
          username: "user",
          password_hash: "$2b$12$test",
          role: :user
        })

      {:ok, regular_token, _claims} = Mydia.Auth.Guardian.encode_and_sign(regular_user)

      conn =
        conn
        |> put_session(:guardian_default_token, regular_token)
        |> put_req_header("authorization", "Bearer #{regular_token}")

      # Regular user should not be able to access admin config
      assert_error_sent(403, fn ->
        get(conn, ~p"/admin/config")
      end)
    end

    test "allows admin access", %{conn: conn, token: token} do
      conn =
        conn
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config")
      assert html =~ "Configuration Management"
    end
  end

  describe "Index - Tabs" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config")
      %{conn: conn, view: view}
    end

    test "renders general settings tab by default", %{view: view} do
      assert has_element?(view, ~s{button[class*="tab-active"]}, "General Settings")
    end

    test "switches to quality profiles tab", %{view: view} do
      view
      |> element(~s{button}, "Quality Profiles")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=quality")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Quality Profiles")
    end

    test "switches to download clients tab", %{view: view} do
      view
      |> element(~s{button}, "Download Clients")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=clients")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Download Clients")
    end

    test "switches to indexers tab", %{view: view} do
      view
      |> element(~s{button}, "Indexers")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=indexers")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Indexers")
    end

    test "switches to library paths tab", %{view: view} do
      view
      |> element(~s{button}, "Library Paths")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=library")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Library Paths")
    end
  end

  describe "Quality Profiles" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=quality")
      %{conn: conn, view: view}
    end

    test "displays empty state when no profiles exist", %{view: view} do
      assert has_element?(view, ~s{div[class*="alert-info"]}, "No quality profiles configured")
    end

    test "displays existing quality profiles", %{view: view} do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "HD",
          min_size_mb: 1000,
          max_size_mb: 5000,
          preferred_quality: "1080p"
        })

      # Reload the view to see the new profile
      {:ok, view, _html} = live(view.pid)

      assert has_element?(view, "td", "HD")
      assert has_element?(view, "td", "1000")
      assert has_element?(view, "td", "5000")
      assert has_element?(view, "td", "1080p")
    end

    test "opens modal when clicking new profile button", %{view: view} do
      view
      |> element(~s{button}, "New Profile")
      |> render_click()

      assert has_element?(view, ~s{div[class*="modal-open"]})
      assert has_element?(view, "h3", "New Quality Profile")
    end

    test "creates a new quality profile", %{view: view} do
      view
      |> element(~s{button}, "New Profile")
      |> render_click()

      view
      |> form("#quality-profile-form",
        quality_profile: %{
          name: "4K Ultra HD",
          min_size_mb: "5000",
          max_size_mb: "20000",
          preferred_quality: "2160p"
        }
      )
      |> render_submit()

      assert has_element?(view, "td", "4K Ultra HD")
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end

    test "validates quality profile form", %{view: view} do
      view
      |> element(~s{button}, "New Profile")
      |> render_click()

      # Submit without required name field
      html =
        view
        |> form("#quality-profile-form", quality_profile: %{name: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "Download Clients" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=clients")
      %{conn: conn, view: view}
    end

    test "displays empty state when no clients exist", %{view: view} do
      assert has_element?(view, ~s{div[class*="alert-info"]}, "No download clients configured")
    end

    test "creates a new download client", %{view: view} do
      view
      |> element(~s{button}, "New Client")
      |> render_click()

      view
      |> form("#download-client-form",
        download_client_config: %{
          name: "qBittorrent",
          type: "qbittorrent",
          host: "localhost",
          port: "8080",
          username: "admin",
          password: "password",
          enabled: "true",
          priority: "1"
        }
      )
      |> render_submit()

      assert has_element?(view, "td", "qBittorrent")
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end

  describe "Indexers" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")
      %{conn: conn, view: view}
    end

    test "displays empty state when no indexers exist", %{view: view} do
      assert has_element?(view, ~s{div[class*="alert-info"]}, "No indexers configured")
    end

    test "creates a new indexer", %{view: view} do
      view
      |> element(~s{button}, "New Indexer")
      |> render_click()

      view
      |> form("#indexer-form",
        indexer_config: %{
          name: "Prowlarr",
          type: "prowlarr",
          base_url: "http://localhost:9696",
          api_key: "test-api-key",
          enabled: "true",
          priority: "1"
        }
      )
      |> render_submit()

      assert has_element?(view, "td", "Prowlarr")
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end

  describe "Library Paths" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=library")
      %{conn: conn, view: view}
    end

    test "displays empty state when no paths exist", %{view: view} do
      assert has_element?(view, ~s{div[class*="alert-info"]}, "No library paths configured")
    end

    test "creates a new library path", %{view: view} do
      view
      |> element(~s{button}, "New Path")
      |> render_click()

      view
      |> form("#library-path-form",
        library_path: %{
          path: "/media/movies",
          type: "movies",
          monitored: "true"
        }
      )
      |> render_submit()

      assert has_element?(view, "td", "/media/movies")
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end
end
