defmodule MydiaWeb.Features.UiHooksTest do
  @moduledoc """
  Client-side hooks that `Phoenix.LiveViewTest` cannot execute.

  `ThemeToggle` mutates the document theme attribute; `PersistedCheckbox`
  writes localStorage. Both are pure browser behavior. The node unit test
  at assets/test/unit/persisted_checkbox.test.mjs covers that module in
  isolation; this covers it wired into a real page and surviving
  navigation.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "ThemeToggle" do
    # `<.theme_toggle>` is rendered TWICE on every authenticated page: in the
    # `lg:hidden` mobile header (id="theme-toggle") and inside the sidebar's
    # account menu (id="theme-toggle-account"). The account menu is a daisyUI
    # focus dropdown, so its copy is not displayed until the trigger
    # `#sidebar-user-menu` has focus. At the pinned 1400px desktop viewport the
    # header copy is `display:none`, so the test opens the account menu and
    # clicks inside `#theme-toggle-account`.
    #
    # The hook itself (`phx-hook="ThemeToggle"`) only tracks the indicator
    # position via a MutationObserver; it does not receive clicks. The three
    # theme buttons inside it call `window.mydiaTheme.setTheme(...)` directly
    # via a plain `onclick`, so `click(Query.css(~s([phx-hook="ThemeToggle"])))`
    # would click the wrapper div rather than a button. Clicking a specific
    # button (by its `title` attribute, layouts.ex theme_toggle/1) is both
    # correct and unambiguous about which theme gets applied.
    @tag :feature
    test "toggling changes the document theme and it survives navigation",
         %{session: session} do
      login_as_admin(session)

      session
      |> resize_window(1400, 1000)
      |> visit_liveview("/")

      before = document_theme(session)

      # Pick whichever fixed-theme button differs from the current theme, so
      # the toggle is guaranteed to produce a real change regardless of
      # which theme a fresh session starts on (the default preference is
      # "system", which resolves to "mydia-light" or "mydia-dark" depending
      # on the browser's own color-scheme preference).
      target_title = if before == "mydia-dark", do: "Light theme", else: "Dark theme"

      session
      |> click(Query.css("#sidebar-user-menu"))
      |> click(Query.css(~s(#theme-toggle-account [title="#{target_title}"])))

      # The DOM write happens in plain JS triggered by a real click, so poll
      # the attribute rather than asserting once. Wallaby's Query retries; a
      # raw attribute read does not.
      after_toggle =
        eventually(
          fn ->
            current = document_theme(session)
            if current != before, do: {:ok, current}, else: :error
          end,
          description: "the document theme to change from #{inspect(before)}"
        )

      refute after_toggle == before

      # `visit/2` is a full browser navigation (not a `<.link navigate>`
      # pushState), so there is no race to poll out here.
      session
      |> visit_liveview("/movies")

      assert document_theme(session) == after_toggle
    end
  end

  describe "PersistedCheckbox" do
    # `PersistedCheckbox` is not on "/". It lives on the import-run start
    # form at lib/mydia_web/live/import_media_live/run_control.ex:71-83,
    # wired to `<input id="auto-import-toggle" phx-hook="PersistedCheckbox"
    # phx-update="ignore" ...>` on the "/import" page (router.ex maps
    # `live "/import", ImportMediaLive.Index, :index`). The hook is on the
    # `<input>` itself, not a wrapping element, so a descendant selector like
    # `[phx-hook="PersistedCheckbox"] input[type="checkbox"]` matches
    # nothing; `#auto-import-toggle` is the real target and is directly
    # clickable (it is a plain visible daisyUI `toggle` checkbox, not a
    # visually-hidden input under a label).
    #
    # The start form only renders once a library path exists to scan
    # (`RunControl.run_control/1` shows an info alert instead when
    # `@library_path` is nil), so this inserts one via the factory.
    #
    # The localStorage key is "mydia:auto-import-confident-matches"
    # (assets/js/hooks/persisted_checkbox.mjs:1). With no stored value the
    # hook defaults the checkbox to checked (mjs:6), which is what a fresh
    # test session sees before the first toggle.
    @tag :feature
    test "a checked box is restored after navigating away and back",
         %{session: session} do
      insert(:library_path)

      login_as_admin(session)

      session
      |> visit_liveview("/import")

      selector = "#auto-import-toggle"

      before = checkbox_checked?(session, selector)

      session
      |> click(Query.css(selector))

      toggled =
        eventually(
          fn ->
            current = checkbox_checked?(session, selector)
            if current != before, do: {:ok, current}, else: :error
          end,
          description: "the checkbox state to change"
        )

      # Both hops are `visit/2` full page loads, so PersistedCheckbox's
      # `mounted()` re-reads localStorage on the way back rather than being
      # skipped as an already-mounted, `phx-update="ignore"`d node.
      session
      |> visit_liveview("/movies")
      |> visit_liveview("/import")

      assert checkbox_checked?(session, selector) == toggled
    end
  end

  # eval_js/3 comes from MydiaWeb.FeatureCase, imported by `use`.
  defp document_theme(session) do
    eval_js(session, "return document.documentElement.getAttribute('data-theme');")
  end

  defp checkbox_checked?(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      return el ? el.checked : null;
      """,
      [selector]
    )
  end
end
