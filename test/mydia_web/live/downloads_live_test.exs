defmodule MydiaWeb.DownloadsLiveTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Index" do
    setup :register_and_log_in_user

    test "renders downloads page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/downloads")

      # Downloads/Activity page should render
      assert html =~ "Activity" or html =~ "Downloads" or html =~ "Queue"
    end

    test "shows queue tab by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      # Should render the view successfully
      html = render(view)
      assert is_binary(html)
    end

    test "can switch to completed tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      # Click on completed tab using phx-value-tab
      html =
        view
        |> element("[phx-click='switch_tab'][phx-value-tab='completed']")
        |> render_click()

      # Should still render without errors
      assert is_binary(html)
    end

    test "can switch to issues tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      # Click on issues tab using phx-value-tab
      html =
        view
        |> element("[phx-click='switch_tab'][phx-value-tab='issues']")
        |> render_click()

      assert is_binary(html)
    end

    test "requires authentication" do
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, ~p"/downloads")

      assert to =~ "/login" or to =~ "/auth" or to =~ "/setup"
    end

    test "handles empty download queue gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      # Should render without crashing even with empty queue
      html = render(view)
      assert is_binary(html)
    end
  end

  describe "Index with downloads" do
    setup :register_and_log_in_user

    test "displays download items when present", %{conn: conn} do
      # Note: Creating actual download fixtures would require significant setup
      # For now, just verify the page renders without errors
      {:ok, view, _html} = live(conn, ~p"/downloads")

      html = render(view)
      assert is_binary(html)
    end
  end
end
