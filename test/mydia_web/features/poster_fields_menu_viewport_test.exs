defmodule MydiaWeb.Features.PosterFieldsMenuViewportTest do
  @moduledoc """
  The Libraries "Show on posters" menu opens on screen, and its eye button
  stays beside the density toggle, at every width.

  Measured on /tv as admin before the fix (selection, re-scan, add, import,
  view mode, density, eye all in one `flex-wrap` bar):

  | viewport | eye                         | menu left edge |
  | -------- | --------------------------- | -------------- |
  | 375      | row 2, left of the bar      | -110           |
  | 640      | alone on row 2, x=16        | -208           |
  | 768      | row 2, left of the bar      | 61             |
  | 1024     | row 2, left of the bar      | 325            |

  The eye was the bar's last child, so it wrapped first and landed at the
  left of a new row, and its `dropdown-end` menu opened leftward off screen.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  @viewports [{375, 812}, {640, 960}, {768, 1024}, {1024, 768}, {1280, 800}, {1440, 900}]

  defp top_of(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      if (!el) return -1;
      return Math.round(el.getBoundingClientRect().top);
      """,
      [selector]
    )
  end

  # daisyUI dropdowns open on :focus-within, so focusing the trigger opens it.
  # A closed menu reports a zero-size rect at the origin, which
  # assert_in_viewport/2 would accept, so prove it actually opened first.
  defp open_menu(session, w) do
    shown =
      eval_js(session, """
      document.querySelector('#poster-fields-menu [role=button]').focus();
      var el = document.querySelector('#poster-fields-menu .dropdown-content');
      var r = el.getBoundingClientRect();
      return el.checkVisibility({visibilityProperty: true}) && r.width > 0 && r.height > 0;
      """)

    assert shown, "at #{w}px the poster fields menu did not open"

    session
  end

  setup do
    insert(:tv_show, title: "Lanternfall")
    :ok
  end

  @tag :feature
  test "the eye sits beside the density toggle and its menu opens on screen",
       %{session: session} do
    login_as_admin(session)

    for {w, h} <- @viewports do
      session
      |> resize_window(w, h)
      |> visit_liveview("/tv")

      assert Wallaby.Browser.has_css?(session, "#poster-fields-menu")

      eye_top = top_of(session, "#poster-fields-menu")
      density_top = top_of(session, "#library-density-toggle")

      assert eye_top == density_top,
             "at #{w}px the eye (top #{eye_top}) wrapped away from the " <>
               "density toggle (top #{density_top})"

      session
      |> open_menu(w)
      |> assert_in_viewport("#poster-fields-menu .dropdown-content")
    end
  end
end
