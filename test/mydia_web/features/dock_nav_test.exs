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
  `library_picker_test.exs` for hit-testing this same element.
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

      # The brief guessed `[phx-hook="DockNav"] a[href="/movies"]`. The dock
      # item is `<.link navigate="/movies" data-dock-link>` (layouts.ex), and
      # `<.link navigate>` compiles to a real `<a href={@navigate} ...>`
      # (phoenix_component.ex), so the guessed selector is exact — no
      # substitution needed beyond confirming it against the source.
      session
      |> click(Query.css(~s([phx-hook="DockNav"] a[href="/movies"])))

      # `<.link navigate>` does a client-side pushState navigation entirely
      # inside JS: unlike the login form's real POST (auth_test.exs), the
      # WebDriver click command returns immediately, before the new page has
      # mounted. `wait_for_liveview/1`'s `[data-phx-main].phx-connected`
      # selector already matches the OLD "/" root, so calling it right after
      # the click races the navigation and can observe the stale page.
      # Polling `current_path/1` (this codebase's `eventually/2`, Task 3)
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
  end
end
