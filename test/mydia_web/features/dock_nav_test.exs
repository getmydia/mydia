defmodule MydiaWeb.Features.DockNavTest do
  @moduledoc """
  The dock navigation hook, plus the stacking assertion that would have
  caught the sidebar-under-dock regression.

  `DockNav` is client-side JS, so `Phoenix.LiveViewTest` cannot execute it.
  The geometry assertions here are the reason this suite exists at all: no
  server-rendered assertion can tell you one element is painted over
  another.

  The dock (`lib/mydia_web/components/layouts.ex`, `mobile_dock/1`) renders
  as `<nav id="mobile-dock" phx-hook="DockNav" class="lg:hidden ...">`, so it
  only paints below Tailwind's `lg` breakpoint (1024px). Every test here
  resizes to a mobile viewport first, matching the precedent already set in
  `add_config_flow_test.exs` for hit-testing this same element.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "Dock navigation" do
    @tag :feature
    test "the dock renders, sits in the viewport, and is not covered", %{session: session} do
      login_as_admin(session)

      session
      |> resize_window(390, 844)
      |> visit("/")
      |> wait_for_liveview()

      assert Wallaby.Browser.has_css?(session, ~s([phx-hook="DockNav"]))

      session
      |> assert_in_viewport(~s([phx-hook="DockNav"]))
      |> refute_covered(~s([phx-hook="DockNav"]))
    end

    @tag :feature
    test "navigating from the dock lands on the target page with a live socket",
         %{session: session} do
      login_as_admin(session)

      session
      |> resize_window(390, 844)
      |> visit("/")
      |> wait_for_liveview()

      # The dock item is `<.link navigate="/movies" data-dock-link>`
      # (layouts.ex), and `<.link navigate>` compiles to a real
      # `<a href={@navigate} ...>` (phoenix_component.ex), so
      # `[phx-hook="DockNav"] a[href="/movies"]` is an exact selector for it.
      session
      |> click(Query.css(~s([phx-hook="DockNav"] a[href="/movies"])))

      # `<.link navigate>` does a client-side pushState navigation entirely
      # inside JS: unlike the login form's real POST (auth_test.exs), the
      # WebDriver click command returns immediately, before the new page has
      # mounted. `wait_for_liveview/1`'s `[data-phx-main].phx-connected`
      # selector already matches the OLD "/" root, so calling it right after
      # the click races the navigation and can observe the stale page.
      # Polling `current_path/1` with `MydiaWeb.FeatureCase.eventually/2`
      # waits out that race before the connected-root check below runs.
      eventually(
        fn ->
          if Wallaby.Browser.current_path(session) == "/movies",
            do: {:ok, :navigated},
            else: :error
        end,
        description: "the dock navigating to /movies"
      )

      session
      |> wait_for_liveview()
      |> assert_path("/movies")

      assert Wallaby.Browser.has_css?(session, "[data-phx-main].phx-connected")
    end

    @tag :feature
    test "the sidebar user menu is tappable while the drawer is open",
         %{session: session} do
      login_as_admin(session)

      session
      |> resize_window(390, 844)
      |> visit("/")
      |> wait_for_liveview()

      # The hamburger is `<label for="main-drawer">` (layouts.ex). A real click
      # on a label toggles its associated checkbox, which is the only thing
      # daisyUI's drawer is driven by.
      session
      |> click(Query.css(~s(label[for="main-drawer"])))

      # Two separate transitions run here and only one of them is visibility.
      # `.drawer-side` flips computed visibility to "visible" at the end of a
      # 0.1s delay, but the sidebar slides in independently: daisyUI puts
      # `transition: translate .3s ease-out` with no delay on
      # `.drawer-side > :not(.drawer-overlay)`, animating `translate: -100%` to
      # `0%`. Waiting on visibility alone therefore probes mid-slide, with the
      # sidebar still partly off screen to the left. Wait on the geometry the
      # assertions below actually depend on.
      eventually(
        fn ->
          script = """
          var aside = document.querySelector('.drawer-side > :not(.drawer-overlay)');
          if (!aside) { return '__missing__'; }
          if (window.getComputedStyle(aside).visibility !== 'visible') { return 'hidden'; }
          return aside.getBoundingClientRect().left;
          """

          case eval_js(session, script) do
            left when is_number(left) and left >= -0.5 -> {:ok, :open}
            _ -> :error
          end
        end,
        description: "the drawer sidebar finishing its slide-in"
      )

      # The sidebar scrolls: scrollHeight runs past the viewport once the
      # admin nav section renders. The user menu only reaches the bottom edge
      # of the screen, where the dock floats, when it is scrolled all the way
      # down, so probe that worst case rather than the initial position.
      scroll_bottom = """
      var side = document.querySelector('.drawer-side');
      if (!side) { return '__missing__'; }
      side.scrollTop = side.scrollHeight;
      return side.scrollTop;
      """

      refute eval_js(session, scroll_bottom) == "__missing__",
             "expected a .drawer-side element to scroll"

      # `refute_covered/2` skips sample points that fall outside the viewport
      # (elementFromPoint returns null there), so an off-screen element would
      # pass vacuously. Assert the rect is on screen first, so the cover check
      # cannot silently no-op.
      session
      |> assert_in_viewport("#sidebar-user-menu")
      |> refute_covered("#sidebar-user-menu")
    end
  end
end
