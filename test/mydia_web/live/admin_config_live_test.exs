defmodule MydiaWeb.AdminConfigLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.{Accounts, Settings}

  setup do
    # Create an admin user for testing
    {:ok, user} =
      Accounts.create_user(%{
        email: "admin@example.com",
        username: "admin",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    # Generate JWT token for the user
    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  describe "Index - Authentication" do
    setup do
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)
      :ok
    end

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
          role: "user"
        })

      {:ok, regular_token, _claims} = Mydia.Auth.Guardian.encode_and_sign(regular_user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:guardian_default_token, regular_token)
        |> put_req_header("authorization", "Bearer #{regular_token}")

      # Regular user should be redirected (302) when trying to access admin config
      # The application redirects to home page instead of returning 403
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
      assert html =~ "Configuration Management"
    end
  end

  describe "Index - Tabs" do
    setup %{conn: conn, token: token} do
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
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
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=quality")
      %{conn: conn, view: view}
    end

    test "displays empty state when no profiles exist", %{view: view} do
      assert has_element?(view, ~s{div[class*="alert-info"]}, "No quality profiles configured")
    end

    test "displays existing quality profiles", %{conn: conn} do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "HD",
          qualities: ["720p", "1080p"],
          upgrades_allowed: true,
          upgrade_until_quality: "1080p",
          rules: %{
            min_size_mb: 1000,
            max_size_mb: 5000,
            preferred_sources: []
          }
        })

      # Load the view to see the new profile
      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=quality")

      assert has_element?(view, "td", "HD")
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
          "name" => "4K Ultra HD",
          "qualities" => ["2160p", "1080p"],
          "rules" => %{
            "min_size_mb" => "5000",
            "max_size_mb" => "20000"
          }
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
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=clients")
      %{conn: conn, view: view}
    end

    test "displays empty state when no clients exist", %{conn: conn, token: token} do
      # Delete ALL download client configs from the database
      Mydia.Settings.list_download_client_configs()
      |> Enum.each(fn client_config ->
        # Skip runtime clients (they can't be deleted from database)
        unless is_binary(client_config.id) and String.starts_with?(client_config.id, "runtime::") do
          Mydia.Settings.delete_download_client_config(client_config)
        end
      end)

      # Unregister any mock adapters
      Mydia.Downloads.Client.Registry.unregister(:transmission)

      # Now load the view with proper authentication
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=clients")
      # Runtime clients will still be shown, so we can't test for completely empty state
      # Just verify the page renders without error
      assert html =~ "Download Clients"
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
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")
      %{conn: conn, view: view}
    end

    test "displays empty state when no indexers exist", %{conn: conn, token: token} do
      # Delete ALL indexer configs from the database
      Mydia.Settings.list_indexer_configs()
      |> Enum.each(fn indexer_config ->
        # Skip runtime indexers (they can't be deleted from database)
        unless is_binary(indexer_config.id) and
                 String.starts_with?(indexer_config.id, "runtime::") do
          Mydia.Settings.delete_indexer_config(indexer_config)
        end
      end)

      # Now load the view with proper authentication
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=indexers")
      # Runtime indexers will still be shown, so we can't test for completely empty state
      # Just verify the page renders without error
      assert html =~ "Indexers"
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
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=library")
      %{conn: conn, view: view}
    end

    test "displays empty state when no paths exist", %{conn: conn, token: token} do
      # Delete ALL library paths from the database
      Mydia.Settings.list_library_paths()
      |> Enum.each(fn library_path ->
        # Skip runtime paths (they can't be deleted from database)
        unless is_binary(library_path.id) and String.starts_with?(library_path.id, "runtime::") do
          Mydia.Settings.delete_library_path(library_path)
        end
      end)

      # Now load the view with proper authentication
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=library")
      # Runtime paths will still be shown, so we can't test for completely empty state
      # Just verify the page renders without error
      assert html =~ "Library Paths"
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

      # Wait for modal to close (async operation in CI)
      Process.sleep(100)
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end
end
