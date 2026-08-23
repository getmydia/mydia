defmodule MydiaWeb.MediaLive.Show.NoHoverDropdownsTest do
  @moduledoc """
  Neither search dialog may explain a score through a daisyUI `dropdown`.

  Two separate defects made that impossible, and both live in CSS rather than
  in anything a rendered-HTML assertion can see:

    * `app.css` hides a `dropdown-hover` panel whenever its trigger has
      `:focus` without `:focus-visible`. That is exactly what a finger tap
      produces, and a touch device has no `:hover`, so the panel was
      unreachable on a phone.
    * `.dropdown-content` is `position: absolute`, and `.modal-box` ships
      `overflow-y: auto`. Absolute positioning does not escape a scroll
      container's clip rect, so no z-index could save the panel. It was cut
      off on desktop too.

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
             "#{path} still explains a score through a dropdown-hover, " <>
               "which cannot be opened by touch"

      refute source =~ "dropdown-content",
             "#{path} still uses an absolutely positioned dropdown-content, " <>
               "which its scrolling ancestor clips"
    end
  end
end
