defmodule MydiaWeb.AdminSettingsLiveTest do
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
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/settings")
      assert path =~ "/auth"
    end
  end

  describe "General Settings" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/settings")
      %{conn: conn, view: view}
    end

    test "toggles authentication settings without :atom.cast/1 error", %{view: view} do
      html =
        view
        |> element("input[type='checkbox'][phx-value-key='auth.local_enabled']")
        |> render_click()

      assert html =~ "Setting updated successfully"
      assert has_element?(view, "div.bg-base-200.rounded-box")
    end

    test "toggles crash reporting setting without category validation error", %{
      view: view,
      user: user
    } do
      case Settings.get_config_setting_by_key("crash_reporting.enabled") do
        nil -> :ok
        existing -> Settings.delete_config_setting(existing)
      end

      html =
        view
        |> element("input[type='checkbox'][phx-value-key='crash_reporting.enabled']")
        |> render_click()

      refute html =~ "Category can&#39;t be blank",
             "Should not have 'Category can't be blank' error"

      refute html =~ "Category can't be blank", "Should not have 'Category can't be blank' error"

      assert html =~ "Setting updated successfully", "Should have success message"
      assert has_element?(view, ".alert-info", "Setting updated successfully")

      setting = Settings.get_config_setting_by_key("crash_reporting.enabled")
      assert setting != nil
      assert setting.category == :crash_reporting
      assert setting.updated_by_id == user.id
    end

    test "toggle persists a value the crash reporter recognises as enabled", %{conn: conn} do
      case Settings.get_config_setting_by_key("crash_reporting.enabled") do
        nil -> :ok
        existing -> Settings.delete_config_setting(existing)
      end

      {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

      view
      |> element("input[type='checkbox'][phx-value-key='crash_reporting.enabled']")
      |> render_click()

      assert Mydia.CrashReporter.enabled?(),
             "expected toggle click to leave CrashReporter.enabled?/0 returning true"
    end

    test "self-heals legacy 'on' value written by older versions", %{conn: conn, user: user} do
      case Settings.get_config_setting_by_key("crash_reporting.enabled") do
        nil -> :ok
        existing -> Settings.delete_config_setting(existing)
      end

      {:ok, _} =
        Settings.create_config_setting(%{
          "key" => "crash_reporting.enabled",
          "value" => "on",
          "category" => "crash_reporting",
          "updated_by_id" => user.id
        })

      assert Mydia.CrashReporter.enabled?(),
             "legacy 'on' value should be interpreted as enabled"

      {:ok, fresh_view, _html} = live(conn, ~p"/admin/config/settings")

      assert has_element?(
               fresh_view,
               "input[type='checkbox'][phx-value-key='crash_reporting.enabled'][checked]"
             ),
             "toggle should render checked when DB holds the legacy 'on' value"
    end

    test "no longer renders a FlareSolverr settings section", %{view: view} do
      html = render(view)
      refute html =~ "FlareSolverr"
      refute has_element?(view, "input[phx-value-key='flaresolverr.url']")
    end

    test "database settings render read-only, never as an editable input", %{view: view} do
      # Mydia.Repo reads pool_size and database_path straight from
      # DATABASE_PATH/POOL_SIZE at boot (config/runtime.exs); this config
      # layer never reaches it. Mydia.Config.Schema.Paths deliberately
      # excludes the `database` section, so a row written from this page is
      # now rejected on write. Neither field is a per-setting :env source
      # here (DATABASE_PATH/POOL_SIZE are unset in test), so without the
      # explicit `editable: false` override these would render as editable
      # text inputs and blurring one would surface "Invalid setting value".
      refute has_element?(view, "input[phx-value-key='database.path']")
      refute has_element?(view, "input[phx-value-key='database.pool_size']")
      assert has_element?(view, "div.text-xs.font-mono.truncate", "database.path")
      assert has_element?(view, "div.text-xs.font-mono.truncate", "database.pool_size")
    end

    test "offers the transcode height ceiling", %{view: view} do
      # The escape hatch for an operator whose hardware cannot encode a 4K
      # file in realtime. It shipped once as a compile-time key in
      # config/config.exs, reachable only by rebuilding the image.
      assert has_element?(
               view,
               "input[phx-value-key='streaming.max_transcode_height']"
             )
    end

    test "persists a typed setting instead of crashing on blur", %{view: view} do
      # `phx-blur` sends the element's value and its phx-value-* metadata, not
      # a `settings` map. Every typed setting in this screen used to raise
      # FunctionClauseError here, which left the database layer reachable for
      # toggles but not for anything an operator types.
      html =
        view
        |> element("input[phx-value-key='streaming.max_transcode_height']")
        |> render_blur(%{"value" => "720"})

      assert html =~ "Setting updated successfully"

      setting = Settings.get_config_setting_by_key("streaming.max_transcode_height")
      assert setting.value == "720"
      assert setting.category == :streaming
    end

    test "blurring an unchanged field writes nothing", %{view: view} do
      # `phx-blur` fires on every blur, including one that only tabbed through.
      # A write there would pin the currently displayed value — which may come
      # from YAML or a schema default — into the database overlay, flipping the
      # provenance badge to DB and shadowing that key from every later YAML or
      # default change.
      html =
        view
        |> element("input[phx-value-key='server.host']")
        |> render_blur(%{"value" => "0.0.0.0"})

      refute html =~ "Setting updated successfully"
      assert Settings.get_config_setting_by_key("server.host") == nil
    end

    test "blurring a changed field still writes", %{view: view} do
      view
      |> element("input[phx-value-key='server.host']")
      |> render_blur(%{"value" => "127.0.0.1"})

      assert Settings.get_config_setting_by_key("server.host").value == "127.0.0.1"
    end
  end

  describe "Crash report widget" do
    setup %{conn: conn, token: token, user: user} do
      start_supervised!(Mydia.Indexers.Health)

      # The stats widget only renders when crash reporting is enabled.
      {:ok, _setting} =
        Settings.upsert_config_setting(%{
          key: "crash_reporting.enabled",
          value: "true",
          category: :crash_reporting,
          updated_by_id: user.id
        })

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/settings")
      %{view: view}
    end

    test "renders the tracked-errors count as a link to the error dashboard", %{view: view} do
      assert has_element?(view, "a#tracked-errors-link[href='/admin/errors']")
    end

    test "no longer renders the 'Sent' tile", %{view: view} do
      refute has_element?(view, ".stat-title", "Sent")
      refute has_element?(view, ".stat-desc", "Successfully reported")
    end
  end
end
