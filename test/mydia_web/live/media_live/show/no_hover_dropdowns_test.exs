defmodule MydiaWeb.MediaLive.Show.NoHoverDropdownsTest do
  @moduledoc """
  Neither search dialog may explain a score through a daisyUI `dropdown`.

  A hover-driven panel cannot be a reliable touch affordance, and the reason is
  in CSS rather than in anything a rendered-HTML assertion can see. `app.css`
  ships:

      .dropdown.dropdown-hover:not(:hover)
        [tabindex]:first-child:focus:not(:focus-visible) ~ .dropdown-content {
          display: none;
        }

  Measured in headless Chromium with touch emulation against the real built
  stylesheet: a tap opens the panel, because the tap leaves sticky `:hover` on
  the trigger. The moment that hover is lost the panel closes again, with the
  trigger still focused (`:focus` true, `:focus-visible` false), because the
  rule above fires. So the panel's visibility is pinned to an emulated hover
  state that no touch platform guarantees, and focus, the one state a tap
  reliably leaves behind, is explicitly excluded from holding it open.

  An inline disclosure opens on an explicit tap and stays open until tapped
  again, on every browser, which is the behavior a touch user can rely on.

  The release dialog's score branch cannot be reached from a component test at
  all: `manual_search_modal/1` builds its own ranking options from DB-backed
  resolvers, so there is no seam to inject a quality profile through. A source
  check is the only honest way to keep that branch from regressing.
  """
  use ExUnit.Case, async: true

  @dialogs [
    "lib/mydia_web/live/media_live/show/subtitle_modal.ex",
    "lib/mydia_web/live/media_live/show/modals.ex"
  ]

  test "no search dialog uses a hover dropdown" do
    for path <- @dialogs do
      assert File.exists?(path), "expected #{path} to exist"

      source = File.read!(path)

      refute source =~ "dropdown-hover",
             "#{path} still explains a score through a dropdown-hover, whose " <>
               "visibility on touch depends on sticky :hover and which daisyUI " <>
               "explicitly refuses to hold open on focus alone"

      refute source =~ "dropdown-content",
             "#{path} still puts a score breakdown in an absolutely positioned " <>
               "dropdown-content, which cannot grow its scrolling ancestor's " <>
               "scroll extent and is a fixed width regardless of the row"
    end
  end
end
