defmodule MydiaWeb.AdminIndexersLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.{Accounts, Settings}

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
    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/indexers")
      assert path =~ "/auth"
    end
  end

  describe "Indexers" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)
      # Ensure real adapters are registered — other async:false test modules (e.g.
      # RegistryTest) call Registry.clear() in their setup and may leave the registry
      # empty or populated with test-only adapters.
      Mydia.Indexers.register_adapters()

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")
      %{conn: conn, view: view}
    end

    test "displays empty state when no indexers exist", %{conn: conn, token: token} do
      Mydia.Settings.list_indexer_configs()
      |> Enum.each(fn indexer_config ->
        unless is_binary(indexer_config.id) and
                 String.starts_with?(indexer_config.id, "runtime::") do
          Mydia.Settings.delete_indexer_config(indexer_config)
        end
      end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config/indexers")
      assert html =~ "Indexers"
    end

    test "creates a new indexer", %{view: view} do
      view
      |> element(~s{button[phx-click="new_indexer"]})
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

      html = render(view)
      assert html =~ "Prowlarr"
      refute has_element?(view, ~s{div[class*="modal-open"]})
    end

    @tag :skip
    test "test connection succeeds with valid prowlarr server", %{view: view} do
      bypass = Bypass.open()
      Mydia.IndexerMock.mock_prowlarr_status(bypass, version: "1.25.0")

      base_url = "http://127.0.0.1:#{bypass.port}"

      assert {:ok, %{version: "1.25.0"}} =
               Mydia.Indexers.test_connection(%{
                 type: :prowlarr,
                 base_url: base_url,
                 api_key: "test-api-key"
               })

      view
      |> element(~s{button[phx-click="new_indexer"]})
      |> render_click()

      view
      |> form("#indexer-form",
        indexer_config: %{
          name: "Test Prowlarr",
          type: "prowlarr",
          base_url: base_url,
          api_key: "test-api-key",
          enabled: "true",
          priority: "1"
        }
      )
      |> render_change()

      html =
        view
        |> element(~s{button[phx-click="test_indexer_connection"]})
        |> render_click()

      if html =~ "Connection failed" do
        error_snippet =
          case Regex.run(~r/Connection failed[^<"]*/, html) do
            [match] -> match
            _ -> "Could not extract error message"
          end

        flunk("Expected 'Connection successful' but got: #{error_snippet}")
      end

      assert html =~ "Connection successful",
             "Expected a flash message with 'Connection successful' but found neither " <>
               "'Connection successful' nor 'Connection failed' in the response"
    end

    @tag :skip
    test "test connection shows error for invalid prowlarr server", %{view: view} do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/api/v1/system/status", fn conn ->
        Plug.Conn.resp(conn, 401, "Unauthorized")
      end)

      view
      |> element(~s{button[phx-click="new_indexer"]})
      |> render_click()

      view
      |> form("#indexer-form",
        indexer_config: %{
          name: "Invalid Prowlarr",
          type: "prowlarr",
          base_url: "http://127.0.0.1:#{bypass.port}",
          api_key: "bad-api-key",
          enabled: "true",
          priority: "1"
        }
      )
      |> render_change()

      html =
        view
        |> element(~s{button[phx-click="test_indexer_connection"]})
        |> render_click()

      assert html =~ "Connection failed",
             "Expected flash 'Connection failed' after test connection. " <>
               "HTML snippet: #{String.slice(html, 0..500)}"
    end
  end

  describe "Runtime Config Protection" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)
      Mydia.Indexers.register_adapters()

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "runtime_config?/1 works with indexer configs" do
      runtime_indexer = %Mydia.Settings.IndexerConfig{
        id: "runtime::indexer::Test Indexer"
      }

      assert Settings.runtime_config?(runtime_indexer) == true

      db_indexer = %Mydia.Settings.IndexerConfig{
        id: Ecto.UUID.generate()
      }

      assert Settings.runtime_config?(db_indexer) == false
    end
  end

  describe "FlareSolverr panel" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)
      Mydia.Indexers.register_adapters()

      fs_env_vars = ~w(
        FLARESOLVERR_URL FLARESOLVERR_ENABLED FLARESOLVERR_TIMEOUT FLARESOLVERR_MAX_TIMEOUT
      )

      Enum.each(fs_env_vars, &System.delete_env/1)

      # Saving reloads the cached runtime config; snapshot and restore it so the
      # mutation does not leak into other tests.
      original_runtime = Application.get_env(:mydia, :runtime_config)

      on_exit(fn ->
        Enum.each(fs_env_vars, &System.delete_env/1)

        if original_runtime do
          Application.put_env(:mydia, :runtime_config, original_runtime)
        else
          Application.delete_env(:mydia, :runtime_config)
        end
      end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "renders the FlareSolverr row, always visible when unconfigured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      assert has_element?(view, "#flaresolverr-panel", "FlareSolverr")
      assert has_element?(view, "#flaresolverr-panel", "not configured")
      assert has_element?(view, ~s{button[phx-click="edit_flaresolverr"]})
    end

    test "env-sourced config shows an ENV badge on the row", %{conn: conn} do
      # .test is an RFC 2606 reserved TLD Mydia.RelayGuard already lets
      # through: a container hostname like "flaresolverr" would resolve to
      # something real elsewhere, so the guard cannot allowlist it, but this
      # fixture only needs to look like one, not resolve as one (#530).
      System.put_env("FLARESOLVERR_URL", "http://env-flaresolverr.test:8191")

      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      assert has_element?(view, "#flaresolverr-panel .badge", "ENV")
    end

    test "Edit opens a modal form with the four config fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view
      |> element(~s{button[phx-click="edit_flaresolverr"]})
      |> render_click()

      assert has_element?(view, "#flaresolverr-form")
      assert has_element?(view, ~s{#flaresolverr-form input[name="flaresolverr[url]"]})
      assert has_element?(view, ~s{#flaresolverr-form input[name="flaresolverr[timeout]"]})
    end

    test "saving the modal form upserts the settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()

      # Saving with enabled: true makes maybe_load_flaresolverr_status/1 fire a
      # real health-check request at this url immediately, so it has to be a
      # host Mydia.RelayGuard already lets through (.test, RFC 2606) rather
      # than a container hostname the guard cannot safely allowlist (#530).
      view
      |> form("#flaresolverr-form",
        flaresolverr: %{
          enabled: "true",
          url: "http://flaresolverr.test:8191",
          timeout: "60000",
          max_timeout: "120000"
        }
      )
      |> render_submit()

      url = Settings.get_config_setting_by_key("flaresolverr.url")
      assert url.value == "http://flaresolverr.test:8191"
      assert url.category == :flaresolverr
      assert Settings.get_config_setting_by_key("flaresolverr.timeout").value == "60000"
      refute has_element?(view, "#flaresolverr-form")

      # The save reloads the runtime config, so the change takes effect without a
      # restart — FlareSolverr now reads enabled/url from the merged config.
      config = Mydia.Indexers.FlareSolverr.config()
      assert config.enabled == true
      assert config.url == "http://flaresolverr.test:8191"
    end

    test "invalid timeout shows a validation error and writes no setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()

      html =
        view
        |> form("#flaresolverr-form",
          flaresolverr: %{enabled: "false", url: "", timeout: "0", max_timeout: "120000"}
        )
        |> render_submit()

      assert html =~ "must be greater than 0"
      assert is_nil(Settings.get_config_setting_by_key("flaresolverr.timeout"))
      assert has_element?(view, "#flaresolverr-form")
    end

    test "Test Connection from the row is handled without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view
      |> element(~s{button[phx-click="test_flaresolverr"]})
      |> render_click()

      assert has_element?(view, "#flaresolverr-panel")
    end

    test "enabling with a blank URL shows a required-error and keeps the modal open", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()

      view
      |> form("#flaresolverr-form",
        flaresolverr: %{enabled: "true", url: "", timeout: "60000", max_timeout: "120000"}
      )
      |> render_submit()

      assert has_element?(view, "#flaresolverr-form")
      assert is_nil(Settings.get_config_setting_by_key("flaresolverr.url"))
    end

    test "max_timeout below timeout shows a validation error and writes no setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()

      html =
        view
        |> form("#flaresolverr-form",
          flaresolverr: %{enabled: "false", url: "", timeout: "120000", max_timeout: "60000"}
        )
        |> render_submit()

      assert html =~ "must be greater than or equal to timeout"
      assert is_nil(Settings.get_config_setting_by_key("flaresolverr.max_timeout"))
      assert has_element?(view, "#flaresolverr-form")
    end

    test "enabling is allowed and the env URL is never persisted when the URL is env-sourced",
         %{conn: conn} do
      # Same reason as "saving the modal form upserts the settings" above:
      # enabled: true fires a real health check at whatever url is
      # effective, so it must resolve nowhere rather than be allowlisted.
      System.put_env("FLARESOLVERR_URL", "http://env-flaresolverr.test:8191")

      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()

      view
      |> form("#flaresolverr-form",
        flaresolverr: %{enabled: "true", timeout: "60000", max_timeout: "120000"}
      )
      |> render_submit()

      # The save is not blocked by the URL-required rule (the URL comes from env),
      # the modal closes, and the env-sourced URL is never written to the DB.
      refute has_element?(view, "#flaresolverr-form")
      assert is_nil(Settings.get_config_setting_by_key("flaresolverr.url"))
      assert Settings.get_config_setting_by_key("flaresolverr.enabled").value == "true"

      # The effective config still reflects the env URL plus the saved enabled flag.
      config = Mydia.Indexers.FlareSolverr.config()
      assert config.enabled == true
      assert config.url == "http://env-flaresolverr.test:8191"
    end

    test "Cancel closes the modal without writing a setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()
      assert has_element?(view, "#flaresolverr-form")

      view |> element(~s{button[phx-click="close_flaresolverr_modal"]}) |> render_click()

      refute has_element?(view, "#flaresolverr-form")
      assert is_nil(Settings.get_config_setting_by_key("flaresolverr.url"))
    end

    test "tolerates a non-integer timeout value stored in the database", %{conn: conn} do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "flaresolverr.timeout",
          value: "not-a-number",
          category: :flaresolverr
        })

      # Should not crash on mount or when opening the edit modal; the malformed
      # value falls back to the schema default rather than raising.
      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")
      view |> element(~s{button[phx-click="edit_flaresolverr"]}) |> render_click()

      assert has_element?(view, "#flaresolverr-form")
    end
  end

  describe "FlareSolverr row and client agreement" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)
      Mydia.Indexers.register_adapters()

      # Env is the highest-precedence config layer (defaults > YAML > database >
      # env), so a FLARESOLVERR_* variable exported on the host running the
      # tests would defeat the stale-config state these tests deliberately
      # build with `Loader.load!(sources: [:yaml, :env])` below, flipping the
      # client to enabled for reasons unrelated to the code under test.
      fs_env_vars = ~w(
        FLARESOLVERR_URL FLARESOLVERR_ENABLED FLARESOLVERR_TIMEOUT FLARESOLVERR_MAX_TIMEOUT
      )
      original_env = Map.new(fs_env_vars, &{&1, System.get_env(&1)})
      Enum.each(fs_env_vars, &System.delete_env/1)

      original = Application.get_env(:mydia, :runtime_config)

      on_exit(fn ->
        Enum.each(original_env, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        Application.put_env(:mydia, :runtime_config, original)
      end)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "the Enabled badge reflects the merged config, not the raw rows", %{conn: conn} do
      # A row saying enabled, with a cached config that has not been reloaded,
      # is exactly the state that produced "badge says Enabled, Test says
      # disabled". Both readers must now answer the same way.
      {:ok, _} =
        Mydia.Settings.upsert_config_setting(%{
          key: "flaresolverr.enabled",
          value: "true",
          category: :flaresolverr
        })

      {:ok, _} =
        Mydia.Settings.upsert_config_setting(%{
          key: "flaresolverr.url",
          value: "http://fs.test:8191",
          category: :flaresolverr
        })

      stale = Mydia.Config.Loader.load!(sources: [:yaml, :env])
      Application.put_env(:mydia, :runtime_config, stale)

      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      refute Mydia.Indexers.FlareSolverr.enabled?()

      assert has_element?(view, "#flaresolverr-panel .badge-ghost", "Disabled"),
             "the badge must agree with FlareSolverr.enabled?/0"
    end

    test "the Enabled badge turns on once the merged config carries the rows", %{conn: conn} do
      {:ok, _} =
        Mydia.Settings.upsert_config_setting(%{
          key: "flaresolverr.enabled",
          value: "true",
          category: :flaresolverr
        })

      {:ok, _} =
        Mydia.Settings.upsert_config_setting(%{
          key: "flaresolverr.url",
          value: "http://fs.test:8191",
          category: :flaresolverr
        })

      assert {:ok, _} = Mydia.Config.Bootstrap.run()

      {:ok, view, _html} = live(conn, ~p"/admin/config/indexers")

      assert Mydia.Indexers.FlareSolverr.enabled?()
      assert has_element?(view, "#flaresolverr-panel .badge-success", "Enabled")
    end
  end
end
