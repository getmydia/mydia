defmodule MydiaWeb.Features.AdminMobileCardsTest do
  @moduledoc """
  The admin hub chrome in a real browser: list cards keep an edge, the switcher
  tab joins the page's panel on narrow screens, and the lifted tab strip stays on
  one line at the widths where it shows.

  The strip's breakpoints come from measured widths: Configuration's nine tabs
  need 842px as labels and 1080px with icons, against 960px beside the sidebar
  in a 1280px window and 1216px in a 1536px one.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  defp resize(session, width, height), do: Wallaby.Browser.resize_window(session, width, height)

  defp style(session, selector, prop) do
    eval_js(session, """
    var el = document.querySelector(#{Jason.encode!(selector)});
    return el ? getComputedStyle(el)[#{Jason.encode!(prop)}] : null;
    """)
  end

  defp rect(session, selector, edge) do
    eval_js(session, """
    var el = document.querySelector(#{Jason.encode!(selector)});
    return el ? el.getBoundingClientRect()[#{Jason.encode!(edge)}] : null;
    """)
  end

  defp tab_count(session) do
    eval_js(session, ~s|return document.querySelectorAll("nav#admin-page-tabs > a").length;|)
  end

  defp tab_rows(session) do
    eval_js(session, """
    var tabs = document.querySelectorAll("nav#admin-page-tabs > a");
    return new Set(Array.from(tabs, function (a) { return Math.round(a.getBoundingClientRect().top); })).size;
    """)
  end

  test "list cards keep an edge inside the bordered panel on a phone", %{session: session} do
    login_as_admin(session)
    resize(session, 390, 844)
    visit_liveview(session, "/admin/indexers")

    assert style(session, "#flaresolverr", "borderTopWidth") == "1px"
    assert style(session, "#admin-page-body", "borderTopWidth") == "1px"
    refute style(session, "#admin-page-body", "backgroundColor") == "rgba(0, 0, 0, 0)"
  end

  test "the switcher is one lifted tab on the panel and navigates", %{session: session} do
    login_as_admin(session)
    resize(session, 390, 844)
    visit_liveview(session, "/admin/indexers")

    assert style(session, "nav#admin-page-tabs", "display") == "none"
    assert rect(session, "#admin-page-switcher-trigger", "height") < 60
    assert style(session, "#admin-page-body", "borderTopLeftRadius") == "0px"

    # The trigger overlaps the panel's top border by 1px, so no seam shows.
    overlap =
      rect(session, "#admin-page-switcher-trigger", "bottom") -
        rect(session, "#admin-page-body", "top")

    assert overlap >= 0.5

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

  test "at 1280px Configuration's strip is one line of labels", %{session: session} do
    login_as_admin(session)
    resize(session, 1280, 900)
    visit_liveview(session, "/admin/indexers")

    assert style(session, "nav#admin-page-switcher", "display") == "none"
    refute style(session, "nav#admin-page-tabs", "display") == "none"
    assert style(session, ~s|#admin-tab-quality span[class*="hero-"]|, "display") == "none"
    assert tab_count(session) == 9
    assert tab_rows(session) == 1

    # The strip overlaps the panel's top border by 1px, so no seam shows.
    overlap =
      rect(session, "#admin-tab-indexers", "bottom") - rect(session, "#admin-page-body", "top")

    assert overlap >= 0.5
  end

  test "at 1536px Configuration's strip is one line with icons", %{session: session} do
    login_as_admin(session)
    resize(session, 1536, 900)
    visit_liveview(session, "/admin/indexers")

    refute style(session, "nav#admin-page-tabs", "display") == "none"

    # The tab is a flex container, so the icon's inline-block computes to block.
    assert style(session, ~s|#admin-tab-quality span[class*="hero-"]|, "display") in [
             "block",
             "inline-block"
           ]

    assert tab_count(session) == 9
    assert tab_rows(session) == 1
  end
end
