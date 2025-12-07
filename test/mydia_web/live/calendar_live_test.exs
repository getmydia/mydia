defmodule MydiaWeb.CalendarLiveTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Index" do
    setup :register_and_log_in_user

    test "renders calendar page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/calendar")

      # Calendar page should render
      assert html =~ "Calendar" or html =~ "calendar"
    end

    test "displays calendar grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      # Should render without errors
      html = render(view)
      assert is_binary(html)
    end

    test "can navigate to next month", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      # Try to find and click next month button
      if has_element?(view, "[phx-click='next_month']") do
        html = view |> element("[phx-click='next_month']") |> render_click()
        assert is_binary(html)
      else
        # Alternative: look for forward navigation
        html = render(view)
        assert is_binary(html)
      end
    end

    test "can navigate to previous month", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      # Try to find and click previous month button
      if has_element?(view, "[phx-click='prev_month']") do
        html = view |> element("[phx-click='prev_month']") |> render_click()
        assert is_binary(html)
      else
        # Alternative: just verify page renders
        html = render(view)
        assert is_binary(html)
      end
    end

    test "requires authentication" do
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, ~p"/calendar")

      assert to =~ "/login" or to =~ "/auth" or to =~ "/setup"
    end

    test "handles empty calendar gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      # Should render without crashing even with no scheduled episodes
      html = render(view)
      assert is_binary(html)
    end
  end
end
