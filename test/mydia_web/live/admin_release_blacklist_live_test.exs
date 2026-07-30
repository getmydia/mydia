defmodule MydiaWeb.AdminReleaseBlacklistLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Downloads.Blacklists

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
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/release-blacklist")
      assert path =~ "/auth"
    end
  end

  describe "Release Blacklist" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/release-blacklist")
      %{conn: conn, view: view}
    end

    test "shows the empty state when no rows exist", %{view: view} do
      assert has_element?(view, "#blacklist-empty")
    end

    test "lists blacklisted releases", %{view: view} do
      {:ok, row} =
        Blacklists.add("nzbhydra2", "abc-1", "Show.S01E01", "par2_failed")

      # Re-render after creating the row.
      render(view)

      # Navigate to refresh the LiveView state by triggering an event.
      render_change(view, "filter", %{"failure_reason" => ""})

      assert has_element?(view, "#blacklist-row-#{row.id}")
      assert has_element?(view, "#remove-#{row.id}")
      assert has_element?(view, "#block-forever-#{row.id}")
    end

    test "remove deletes the row", %{view: view} do
      {:ok, row} =
        Blacklists.add("nzbhydra2", "abc-rm", "Show.S01E02", "stalled")

      # Refresh data so the row appears.
      render_change(view, "filter", %{"failure_reason" => ""})
      assert has_element?(view, "#blacklist-row-#{row.id}")

      view
      |> element("#remove-#{row.id}")
      |> render_click()

      refute has_element?(view, "#blacklist-row-#{row.id}")
      refute Blacklists.blacklisted?("nzbhydra2", "abc-rm")
    end

    test "block_forever clears expires_at", %{view: view} do
      {:ok, row} =
        Blacklists.add("nzbhydra2", "abc-bf", "Show.S01E03", "stalled")

      assert row.expires_at != nil

      render_change(view, "filter", %{"failure_reason" => ""})

      view
      |> element("#block-forever-#{row.id}")
      |> render_click()

      updated = Blacklists.get!(row.id)
      assert is_nil(updated.expires_at)
    end

    test "filters by failure reason", %{view: view} do
      {:ok, row_par2} =
        Blacklists.add("nzbhydra2", "filter-1", "T1", "par2_failed")

      {:ok, row_stalled} =
        Blacklists.add("nzbhydra2", "filter-2", "T2", "stalled")

      render_change(view, "filter", %{"failure_reason" => "par2_failed"})

      assert has_element?(view, "#blacklist-row-#{row_par2.id}")
      refute has_element?(view, "#blacklist-row-#{row_stalled.id}")
    end

    test "clear_filter resets the failure_reason filter", %{view: view} do
      {:ok, row_par2} =
        Blacklists.add("nzbhydra2", "clear-1", "T1", "par2_failed")

      {:ok, row_stalled} =
        Blacklists.add("nzbhydra2", "clear-2", "T2", "stalled")

      render_change(view, "filter", %{"failure_reason" => "par2_failed"})
      refute has_element?(view, "#blacklist-row-#{row_stalled.id}")

      # The clear-filter button is only rendered when a filter is active.
      view |> element("#clear-filter-btn") |> render_click()

      assert has_element?(view, "#blacklist-row-#{row_par2.id}")
      assert has_element?(view, "#blacklist-row-#{row_stalled.id}")
    end
  end

  describe "failure reason rendering" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "renders a humanized label in the badge, keeping the slug as a tooltip",
         %{conn: conn} do
      Blacklists.add("prowlarr", "guid-1", "Some.Release", "missing_files")

      {:ok, view, _html} = live(conn, ~p"/admin/release-blacklist")

      assert has_element?(view, "#blacklist-rows span[title='missing_files']", "missing files")
    end

    test "keeps the filter option value as the raw slug", %{conn: conn} do
      # The option VALUE must stay the slug so the phx-change filter still
      # matches stored rows; only the visible text is humanized.
      Blacklists.add("prowlarr", "guid-2", "Other.Release", "client_reported_failure")

      {:ok, view, _html} = live(conn, ~p"/admin/release-blacklist")

      assert has_element?(
               view,
               "#failure-reason-filter option[value='client_reported_failure']",
               "client reported failure"
             )
    end
  end
end
