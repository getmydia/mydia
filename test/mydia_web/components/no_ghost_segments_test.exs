defmodule MydiaWeb.Components.NoGhostSegmentsTest do
  @moduledoc """
  A segmented control must never mark its unselected options `btn-ghost`.

  daisyUI sets `--btn-bg: #0000` for `btn-ghost`, so the segment computes to
  `alpha=0` and paints the page background exactly. Beside a `btn-primary`
  sibling in dark mode the group renders as one blue chip with loose glyphs
  next to it, which is the bug `MydiaWeb.SegmentedControl` exists to prevent.

  All-ghost action strips (an admin table row's edit/duplicate/delete buttons)
  are fine and deliberately excluded: they have no selected sibling, so the
  low-emphasis treatment is the point.
  """

  use ExUnit.Case, async: true

  @web_root Path.expand("../../../lib/mydia_web", __DIR__)

  test "no source file pairs btn-ghost with btn-primary on join-item siblings" do
    offenders =
      [Path.join(@web_root, "**/*.ex"), Path.join(@web_root, "**/*.heex")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&ghost_segment?/1)

    assert offenders == [],
           """
           These files put btn-ghost and btn-primary on join-item siblings, which
           leaves the unselected segments with no visible body in dark mode.
           Use <.segmented_control> instead:

           #{Enum.map_join(offenders, "\n", &("  " <> Path.relative_to(&1, @web_root)))}
           """
  end

  # A naive whole-file split on every `join` class occurrence (the join
  # container itself, or any `join-item` member) over-reaches: a file's last
  # join-related match is routinely an all-ghost admin action strip (edit /
  # duplicate / delete), and the text after it runs unbounded to EOF, so it
  # swallows any unrelated btn-primary elsewhere in the same file, such as a
  # modal's Save button or a "New X" button that shares nothing with the
  # join. That produced 13 false positives across lib/mydia_web on the
  # finished tree (admin_*_live/components.ex and friends), none of them
  # near each other, let alone in the same join.
  #
  # Scan per opening tag instead: `class=` up to that tag's own closing `>`
  # is one element's complete class expression, whether it is a plain string
  # or a `class={[...]}` list. A file offends only when some tag combines
  # `join-item` with `btn-ghost` and some tag combines `join-item` with
  # `btn-primary`, which is what a ghost-vs-primary mismatch inside one join
  # looks like at the markup level, regardless of whether the button markup
  # is written inline or shared through a helper component (as in
  # `MydiaWeb.SegmentedControl`'s own private `segment/1`, whose single
  # class list applies `btn-primary` or `btn-ghost` conditionally on
  # `@selected?`).
  defp ghost_segment?(path) do
    tags =
      path
      |> File.read!()
      |> then(&Regex.scan(~r/class=[\s\S]*?>/, &1))
      |> Enum.map(&hd/1)

    Enum.any?(tags, &(&1 =~ "join-item" and &1 =~ "btn-ghost")) and
      Enum.any?(tags, &(&1 =~ "join-item" and &1 =~ "btn-primary"))
  end
end
