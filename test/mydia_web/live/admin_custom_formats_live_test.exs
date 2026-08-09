defmodule MydiaWeb.AdminCustomFormatsLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  test "lists the built-in formats", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    assert has_element?(view, "#custom-format-row-lang-vff")
    assert has_element?(view, "#custom-format-row-lang-vfq")
  end

  test "opens the edit modal for a built-in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-edit-lang-vff") |> render_click()
    assert has_element?(view, "#custom-format-form")
  end

  test "creates a user format", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-new") |> render_click()

    view
    |> form("#custom-format-form",
      custom_format: %{name: "Dual Audio", patterns_text: "\\bDUAL\\b"}
    )
    |> render_submit()

    assert has_element?(view, "#custom-format-row-dual-audio")
  end

  test "rejects an invalid pattern with a visible error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-new") |> render_click()

    html =
      view
      |> form("#custom-format-form", custom_format: %{name: "Bad", patterns_text: "(unclosed"})
      |> render_submit()

    assert html =~ "parenthesis"
    refute has_element?(view, "#custom-format-row-bad")
  end

  test "the test box reports which patterns match a title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-edit-lang-vff") |> render_click()

    html =
      view
      |> form("#custom-format-form", custom_format: %{test_title: "Film.2024.VFF.1080p"})
      |> render_change()

    assert html =~ "custom-format-test-match"
  end

  test "resetting a built-in restores its shipped patterns", %{conn: conn} do
    {:ok, _} =
      Mydia.Settings.CustomFormats.override_builtin("lang-vff", %{
        name: "VFF",
        patterns: ["\\bONLYVFF\\b"]
      })

    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-reset-lang-vff") |> render_click()

    assert Mydia.Settings.CustomFormats.get("lang-vff").patterns ==
             ["\\bVFF\\b", "\\bTRUEFRENCH\\b"]
  end
end
