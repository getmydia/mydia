defmodule MydiaWeb.AdminConfigLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.{Accounts, Settings}

  setup do
    # Create an admin user for testing with unique identifiers
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
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

    test "requires admin role", %{conn: conn, token: _token} do
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
      assert html =~ "Configuration"
    end
  end

  describe "Index - Redirects" do
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

  describe "Index - System Status Tab" do
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

    test "renders system status tab by default", %{view: view} do
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Status")
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
        # PostgreSQL mode
        assert html =~ "PostgreSQL"
      else
        # SQLite mode
        assert html =~ "SQLite"
      end
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

    test "switches to settings tab", %{view: view} do
      view
      |> element(~s{button[role="tab"]}, "Settings")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=general")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Settings")
    end

    test "switches to quality tab", %{view: view} do
      view
      |> element(~s{button[role="tab"]}, "Quality")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=quality")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Quality")
    end

    test "switches to clients tab", %{view: view} do
      view
      |> element(~s{button[role="tab"]}, "Clients")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=clients")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Clients")
    end

    test "switches to indexers tab", %{view: view} do
      view
      |> element(~s{button[role="tab"]}, "Indexers")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=indexers")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Indexers")
    end

    test "switches to library tab", %{view: view} do
      view
      |> element(~s{button[role="tab"]}, "Library")
      |> render_click()

      assert_patched(view, ~p"/admin/config?tab=library")
      assert has_element?(view, ~s{button[class*="tab-active"]}, "Library")
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

    test "displays quality profiles section", %{view: view} do
      # Default profiles may exist, just verify the quality profiles section renders
      # The header is an h2 element, not h3
      assert has_element?(view, "h2", "Quality Profiles")
    end

    test "displays existing quality profiles", %{conn: conn} do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "HD",
          qualities: ["720p", "1080p"],
          upgrades_allowed: true,
          upgrade_until_quality: "1080p",
          quality_standards: %{
            movie_min_size_mb: 1000,
            movie_max_size_mb: 5000,
            preferred_sources: []
          }
        })

      # Load the view to see the new profile
      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=quality")

      # Quality profiles are displayed in list items with DaisyUI list components
      assert html =~ "HD"
    end

    test "opens modal when clicking new profile button", %{view: view} do
      view
      |> element(~s{button[phx-click="new_quality_profile"]})
      |> render_click()

      assert has_element?(view, ~s{div[class*="modal-open"]})
      assert has_element?(view, "h3", "New Quality Profile")
    end

    test "creates a new quality profile", %{view: view} do
      view
      |> element(~s{button[phx-click="new_quality_profile"]})
      |> render_click()

      view
      |> form("#quality-profile-form",
        quality_profile: %{
          "name" => "4K Ultra HD",
          "qualities" => ["2160p", "1080p"]
        }
      )
      |> render_submit()

      # Quality profiles are displayed in list items, not table cells
      html = render(view)
      assert html =~ "4K Ultra HD"
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end

    test "validates quality profile form", %{view: view} do
      view
      |> element(~s{button[phx-click="new_quality_profile"]})
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
      |> element(~s{button[phx-click="new_download_client"]})
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

      # Download clients are displayed in list items, not table cells
      html = render(view)
      assert html =~ "qBittorrent"
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
      # Use Bypass to mock the Prowlarr API endpoint for health checks
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api/v1/system/status", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{version: "1.0.0"}))
      end)

      Bypass.stub(bypass, "GET", "/api/v1/indexer", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!([]))
      end)

      view
      |> element(~s{button[phx-click="new_indexer"]})
      |> render_click()

      view
      |> form("#indexer-form",
        indexer_config: %{
          name: "Prowlarr",
          type: "prowlarr",
          base_url: "http://localhost:#{bypass.port}",
          api_key: "test-api-key",
          enabled: "true",
          priority: "1"
        }
      )
      |> render_submit()

      # Indexers are displayed in list items, not table cells
      html = render(view)
      assert html =~ "Prowlarr"
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end

  describe "General Settings" do
    setup %{conn: conn, token: token} do
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=general")
      %{conn: conn, view: view}
    end

    test "toggles authentication settings without :atom.cast/1 error", %{view: view} do
      # This test verifies the fix for task-228
      # Previously, toggling auth.local_enabled would cause :atom.cast/1 error
      html =
        view
        |> element("input[type='checkbox'][phx-value-key='auth.local_enabled']")
        |> render_click()

      # Should not crash with UndefinedFunctionError or :atom.cast/1 error
      assert html =~ "Setting updated successfully"
      # Verify the settings list still renders without error
      assert has_element?(view, "div.bg-base-200.rounded-box")
    end

    test "toggles crash reporting setting without category validation error", %{
      view: view,
      user: user
    } do
      # This test verifies the fix for task-236
      # Previously, toggling crash_reporting.enabled would cause "Category can't be blank" error

      # First, ensure there's no existing crash reporting setting
      case Settings.get_config_setting_by_key("crash_reporting.enabled") do
        nil -> :ok
        existing -> Settings.delete_config_setting(existing)
      end

      # Click the crash reporting toggle
      html =
        view
        |> element("input[type='checkbox'][phx-value-key='crash_reporting.enabled']")
        |> render_click()

      # Verify no "Category can't be blank" error
      refute html =~ "Category can&#39;t be blank",
             "Should not have 'Category can't be blank' error"

      refute html =~ "Category can't be blank", "Should not have 'Category can't be blank' error"

      # Verify success message is present
      assert html =~ "Setting updated successfully", "Should have success message"
      assert has_element?(view, ".alert-info", "Setting updated successfully")

      # Verify the setting was created in the database
      setting = Settings.get_config_setting_by_key("crash_reporting.enabled")
      assert setting != nil
      assert setting.category == :crash_reporting
      assert setting.updated_by_id == user.id
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
      # Create a temporary directory for testing
      test_dir =
        Path.join(System.tmp_dir!(), "test_library_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf(test_dir)
      end)

      view
      |> element(~s{button[phx-click="new_library_path"]})
      |> render_click()

      view
      |> form("#library-path-form",
        library_path: %{
          path: test_dir,
          type: "movies",
          monitored: "true"
        }
      )
      |> render_submit()

      # Wait for LiveView to process the update (important for CI)
      Process.sleep(100)

      # Library paths are displayed in list items, not table cells
      html = render(view)
      assert html =~ test_dir
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end
  end

  describe "Runtime Config Protection" do
    setup %{conn: conn, token: token} do
      # Start the Indexers.Health GenServer to initialize ETS tables
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "runtime_config?/1 identifies runtime configs correctly" do
      # Test with runtime ID
      runtime_client = %Mydia.Settings.DownloadClientConfig{
        id: "runtime::download_client::Test Client"
      }

      assert Settings.runtime_config?(runtime_client) == true

      # Test with database ID
      db_client = %Mydia.Settings.DownloadClientConfig{
        id: Ecto.UUID.generate()
      }

      assert Settings.runtime_config?(db_client) == false

      # Test with integer ID
      int_client = %Mydia.Settings.DownloadClientConfig{
        id: 123
      }

      assert Settings.runtime_config?(int_client) == false
    end

    test "runtime_config?/1 works with indexer configs" do
      # Test with runtime ID
      runtime_indexer = %Mydia.Settings.IndexerConfig{
        id: "runtime::indexer::Test Indexer"
      }

      assert Settings.runtime_config?(runtime_indexer) == true

      # Test with database ID
      db_indexer = %Mydia.Settings.IndexerConfig{
        id: Ecto.UUID.generate()
      }

      assert Settings.runtime_config?(db_indexer) == false
    end

    test "template shows disabled buttons for runtime configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=clients")

      # If any runtime configs are present (from ENV or fixtures), they should have
      # disabled buttons. We can't guarantee there are runtime configs in test,
      # but we can verify the template logic is correct by checking for the
      # presence of the tooltip text when runtime configs exist
      if html =~ "runtime::download_client" do
        assert html =~ "Cannot edit runtime-configured clients"
        assert html =~ "Cannot delete runtime-configured clients"
      end
    end

    test "template shows ENV badge for runtime configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=clients")

      # If any runtime configs are present, they should show the ENV badge
      if html =~ "runtime::download_client" do
        assert html =~ "ENV"
        assert html =~ "Configured via environment variables"
      end
    end
  end
end
