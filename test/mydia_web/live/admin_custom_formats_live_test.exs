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

  # Without a nav entry the page is reachable only by typing the URL, which for
  # a self-hosted operator means the feature may as well not exist.
  test "is reachable from the admin tab nav", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    assert has_element?(view, ~s|a[href="/admin/config/custom-formats"]|)
  end

  test "the admin nav on a sibling page links here", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/quality")

    assert has_element?(view, ~s|a[href="/admin/config/custom-formats"]|)
  end

  test "opens the edit modal for a built-in", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-edit-lang-vff") |> render_click()
    assert has_element?(view, "#custom-format-form")
  end

  test "saves an override for a built-in format without submitting the disabled name", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/admin/config/custom-formats")

    view |> element("#custom-format-edit-lang-vff") |> render_click()

    view
    |> form("#custom-format-form",
      custom_format: %{
        description: "French true dub",
        patterns_text: "\\bVFF\\b\n\\bONLYVFF\\b"
      }
    )
    |> render_submit()

    format = Mydia.Settings.CustomFormats.get("lang-vff")
    assert format.overridden?
    assert format.name == "VFF"
    assert "\\bONLYVFF\\b" in format.patterns
    assert has_element?(view, "#custom-format-row-lang-vff .badge-warning", "Edited")
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
    assert html =~ "(unclosed"
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
