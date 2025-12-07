defmodule MydiaWeb.AdminConfigLive.IndexerLibraryTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.IndexersFixtures

  alias Mydia.Indexers

  describe "indexer library modal" do
    setup :register_and_log_in_admin
    setup :start_indexers_health

    test "shows Browse Indexer Library option when feature flag is enabled", %{conn: conn} do
      set_cardigann_feature_flag(true)

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=indexers")
      # The "Add Indexer" dropdown should have "Browse Indexer Library" option
      assert html =~ "Browse Indexer Library"
    end

    test "does not show Browse Indexer Library option when feature flag is disabled", %{
      conn: conn
    } do
      set_cardigann_feature_flag(false)

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=indexers")
      # The "Add Indexer" dropdown should NOT have "Browse Indexer Library" option
      refute html =~ "Browse Indexer Library"
    end

    test "opens indexer library modal when clicking Browse Indexer Library", %{conn: conn} do
      set_cardigann_feature_flag(true)

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Click the "Browse Indexer Library" button (in dropdown) to open the modal
      html =
        view
        |> element("button.flex.items-start[phx-click='show_indexer_library']")
        |> render_click()

      # Modal should be visible with the Indexer Library title
      assert html =~ "Indexer Library"
      assert html =~ "Browse and enable indexers from the definition library"
    end

    test "displays stats correctly in modal", %{conn: conn} do
      set_cardigann_feature_flag(true)

      # Create some test definitions
      cardigann_definition_fixture(%{enabled: true})
      cardigann_definition_fixture(%{enabled: false})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      # Render the whole view to see the modal content
      html = render(view)

      # Check that the modal is open and contains the stats
      assert html =~ "modal modal-open"
      assert html =~ "Indexer Library"
    end

    test "closes modal when clicking close button", %{conn: conn} do
      set_cardigann_feature_flag(true)

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      # Close the modal using footer close button
      html =
        view
        |> element("div.modal-action button[phx-click='close_indexer_library']")
        |> render_click()

      # Modal should be closed
      refute html =~ "Browse and enable indexers from the definition library"
    end
  end

  describe "filters" do
    setup :register_and_log_in_admin
    setup :enable_cardigann_feature_flag
    setup :start_indexers_health

    test "filters by type", %{conn: conn} do
      public_def = cardigann_definition_fixture(%{name: "Public Indexer", type: "public"})

      private_def =
        cardigann_definition_fixture(%{name: "Private Indexer", type: "private"})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      # Filter by public
      html =
        view
        |> element("form#indexer-library-filter-form")
        |> render_change(%{"type" => "public"})

      assert html =~ public_def.name
      refute html =~ private_def.name
    end

    test "filters by enabled status", %{conn: conn} do
      enabled_def = cardigann_definition_fixture(%{name: "Enabled Indexer", enabled: true})

      disabled_def =
        cardigann_definition_fixture(%{name: "Disabled Indexer", enabled: false})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      # Filter by enabled
      html =
        view
        |> element("form#indexer-library-filter-form")
        |> render_change(%{"enabled" => "enabled"})

      assert html =~ enabled_def.name
      refute html =~ disabled_def.name
    end

    test "searches by name", %{conn: conn} do
      indexer1 = cardigann_definition_fixture(%{name: "RARBG"})
      indexer2 = cardigann_definition_fixture(%{name: "1337x"})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      # Search for RARBG
      html =
        view
        |> element("form#indexer-library-search-form")
        |> render_change(%{"search" => %{"query" => "RARBG"}})

      assert html =~ indexer1.name
      refute html =~ indexer2.name
    end
  end

  describe "toggle indexer" do
    setup :register_and_log_in_admin
    setup :enable_cardigann_feature_flag
    setup :start_indexers_health

    test "enables a disabled indexer", %{conn: conn} do
      definition = cardigann_definition_fixture(%{enabled: false})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      view
      |> element(
        "input[type='checkbox'][phx-click='toggle_indexer'][phx-value-id='#{definition.id}']"
      )
      |> render_click()

      # Verify the indexer is now enabled
      updated_definition = Indexers.get_cardigann_definition!(definition.id)
      assert updated_definition.enabled
    end

    test "disables an enabled indexer", %{conn: conn} do
      definition = cardigann_definition_fixture(%{enabled: true})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      view
      |> element(
        "input[type='checkbox'][phx-click='toggle_indexer'][phx-value-id='#{definition.id}']"
      )
      |> render_click()

      # Verify the indexer is now disabled
      updated_definition = Indexers.get_cardigann_definition!(definition.id)
      refute updated_definition.enabled
    end
  end

  describe "configure indexer" do
    setup :register_and_log_in_admin
    setup :enable_cardigann_feature_flag
    setup :start_indexers_health

    test "opens configuration modal for private indexers", %{conn: conn} do
      definition = cardigann_definition_fixture(%{type: "private", name: "Private Site"})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the library modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='configure_indexer'][phx-value-id='#{definition.id}']")
        |> render_click()

      assert html =~ "Configure Private Site"
      assert html =~ "Username"
      assert html =~ "Password"
    end

    test "saves configuration", %{conn: conn} do
      definition = cardigann_definition_fixture(%{type: "private"})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the library modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      # Open config modal
      view
      |> element("button[phx-click='configure_indexer'][phx-value-id='#{definition.id}']")
      |> render_click()

      # Submit config
      view
      |> element("form#indexer-config-form")
      |> render_submit(%{
        "config" => %{
          "username" => "testuser",
          "password" => "testpass"
        }
      })

      # Verify config was saved
      updated_definition = Indexers.get_cardigann_definition!(definition.id)
      assert updated_definition.config["username"] == "testuser"
      assert updated_definition.config["password"] == "testpass"
    end
  end

  describe "empty states" do
    setup :register_and_log_in_admin
    setup :enable_cardigann_feature_flag
    setup :start_indexers_health

    test "shows message when no indexers exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      html =
        view
        |> element("button.flex.items-start[phx-click='show_indexer_library']")
        |> render_click()

      assert html =~ "No indexer definitions available"
      assert html =~ "Sync Library"
    end

    test "shows message when filters return no results", %{conn: conn} do
      cardigann_definition_fixture(%{type: "public"})

      {:ok, view, _html} = live(conn, ~p"/admin/config?tab=indexers")

      # Open the modal using dropdown button
      view
      |> element("button.flex.items-start[phx-click='show_indexer_library']")
      |> render_click()

      html =
        view
        |> element("form#indexer-library-filter-form")
        |> render_change(%{"type" => "private"})

      assert html =~ "No indexers match your filters"
    end
  end

  describe "unified indexers tab" do
    setup :register_and_log_in_admin
    setup :start_indexers_health

    test "shows library indexers section when enabled indexers exist", %{conn: conn} do
      set_cardigann_feature_flag(true)

      # Create an enabled library indexer
      cardigann_definition_fixture(%{name: "Enabled Library Indexer", enabled: true})

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=indexers")

      # Should show the Library Indexers section
      assert html =~ "Library Indexers"
      assert html =~ "Enabled Library Indexer"
    end

    test "does not show library indexers section when no enabled indexers exist", %{conn: conn} do
      set_cardigann_feature_flag(true)

      # Create a disabled library indexer only
      cardigann_definition_fixture(%{name: "Disabled Library Indexer", enabled: false})

      {:ok, _view, html} = live(conn, ~p"/admin/config?tab=indexers")

      # Should NOT show the Library Indexers section (since no enabled ones exist)
      refute html =~ "Disabled Library Indexer"
    end

    test "no Cardigann terminology visible in UI", %{conn: conn} do
      set_cardigann_feature_flag(true)

      cardigann_definition_fixture(%{name: "Test Indexer", enabled: true})

      {:ok, view, html} = live(conn, ~p"/admin/config?tab=indexers")

      # Should not contain "Cardigann" anywhere
      refute html =~ "Cardigann"

      # Open the modal using dropdown button and check it too
      modal_html =
        view
        |> element("button.flex.items-start[phx-click='show_indexer_library']")
        |> render_click()

      refute modal_html =~ "Cardigann"
    end
  end

  # Helper functions

  defp enable_cardigann_feature_flag(_context) do
    set_cardigann_feature_flag(true)
    :ok
  end

  defp start_indexers_health(_context) do
    start_supervised!(Mydia.Indexers.Health)
    :ok
  end

  defp set_cardigann_feature_flag(enabled) do
    current_features = Application.get_env(:mydia, :features, [])
    updated_features = Keyword.put(current_features, :cardigann_enabled, enabled)
    Application.put_env(:mydia, :features, updated_features)

    on_exit(fn ->
      Application.put_env(:mydia, :features, current_features)
    end)
  end
end
