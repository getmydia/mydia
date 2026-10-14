defmodule MydiaWeb.Features.AdminMobileCardsTest do
  @moduledoc """
  On a phone, admin list cards have a visible edge on the page background, and
  the hub's pages are one line tall.

  Before the fix, at 390x844, `admin_list` was base-200 on a base-200 page with
  no border, inside a base-100 body that showed only as stripes, and the
  Configuration hub's tabs wrapped to three lines.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  defp phone(session), do: Wallaby.Browser.resize_window(session, 390, 844)
  defp desktop(session), do: Wallaby.Browser.resize_window(session, 1280, 900)

  defp style(session, selector, prop) do
    eval_js(session, """
    var el = document.querySelector(#{Jason.encode!(selector)});
    return el ? getComputedStyle(el)[#{Jason.encode!(prop)}] : null;
    """)
  end

  defp height(session, selector) do
    eval_js(session, """
    var el = document.querySelector(#{Jason.encode!(selector)});
    return el ? el.getBoundingClientRect().height : null;
    """)
  end

  test "list cards have an edge and the body has no fill on a phone", %{session: session} do
    login_as_admin(session)
    phone(session)
    visit_liveview(session, "/admin/indexers")

    assert style(session, "#flaresolverr", "borderTopWidth") == "1px"
    assert style(session, "#admin-page-body", "backgroundColor") == "rgba(0, 0, 0, 0)"
  end

  test "the hub's pages are one line on a phone and navigate", %{session: session} do
    login_as_admin(session)
    phone(session)
    visit_liveview(session, "/admin/indexers")

    assert style(session, "nav#admin-page-tabs", "display") == "none"
    assert height(session, "#admin-page-switcher-trigger") < 60

    js_click(session, "#admin-page-switcher-trigger")
    js_click(session, "a#admin-switcher-clients")

    # Live navigation is asynchronous and assert_path/2 does not wait.
    eventually(
      fn ->
        if Wallaby.Browser.current_path(session) == "/admin/clients",
          do: {:ok, true},
          else: :error
      end,
      description: "navigation to /admin/clients"
    )
  end

  test "desktop keeps the tab strip and the filled body", %{session: session} do
    login_as_admin(session)
    desktop(session)
    visit_liveview(session, "/admin/indexers")

    assert style(session, "nav#admin-page-switcher", "display") == "none"
    refute style(session, "nav#admin-page-tabs", "display") == "none"
    refute style(session, "#admin-page-body", "backgroundColor") == "rgba(0, 0, 0, 0)"
  end
end
