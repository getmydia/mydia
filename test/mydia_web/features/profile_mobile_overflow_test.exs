defmodule MydiaWeb.Features.ProfileMobileOverflowTest do
  @moduledoc """
  The profile page fits a phone.

  Measured before the fix at 320 to 414px wide, the document was 428px wide:
  the corners picker, a daisyUI `join` that neither wraps nor shrinks, needed
  368px, and the page grid's single implicit column grew to fit it, widening
  every card. At 320px the clock picker overflowed as well.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  @controls ~w(#theme-picker #theme-radius-picker #clock-format-picker)

  defp overflow(session) do
    eval_js(session, """
    var d = document.documentElement;
    return d.scrollWidth > d.clientWidth + 1 ? d.scrollWidth - d.clientWidth : 0;
    """)
  end

  # Each control's bounding box against the viewport, or a distinct string when
  # it is missing or zero-sized, so a control that failed to render can never
  # pass as "inside the viewport".
  defp control_report(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      if (!el) return "missing";
      var r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return "zero-sized";
      var vw = document.documentElement.clientWidth;
      return (r.left >= 0 && r.right <= vw + 1) ? "ok" : "outside: " + Math.round(r.left) + ".." + Math.round(r.right) + " of " + vw;
      """,
      [selector]
    )
  end

  for {w, h} <- [{360, 800}, {320, 640}] do
    @tag :feature
    test "fits a #{w}px phone", %{session: session} do
      login_as_admin(session)
      Wallaby.Browser.resize_window(session, unquote(w), unquote(h))
      visit_liveview(session, "/profile")

      assert overflow(session) == 0, "document overflows by #{overflow(session)}px"

      for selector <- @controls do
        assert control_report(session, selector) == "ok",
               "#{selector}: #{control_report(session, selector)}"
      end
    end
  end
end
