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

  test "the scanner does not let a > inside a class expression truncate the value" do
    # This is the exact shape a reviewer found could defeat a naive
    # `class=[\s\S]*?>` scan: `@count > 3` inside the class list has its own
    # literal `>`, so a non-greedy match to "the next >" stops there instead
    # of at the tag's closing bracket, and btn-primary/btn-ghost after it are
    # never seen. Assert the real extractor keeps going past it.
    fixture = ~S"""
    <button class={["btn join-item", @count > 3 && "btn-primary", !@selected? && "btn-ghost"]}>
    """

    assert offends?(fixture)
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
  # Scan per class attribute VALUE instead of per tag. `class="..."` and
  # `class={...}` are extracted properly rather than by scanning to a `>`:
  # a plain string runs to the next `"`, and a `{...}` expression is walked
  # char by char counting brace depth, so a `>` or `->` inside the
  # expression (a guard, a `cond`, an interpolation) cannot be mistaken for
  # the end of the value. A file offends only when some class value combines
  # `join-item` with `btn-ghost` and some class value combines `join-item`
  # with `btn-primary`, which is what a ghost-vs-primary mismatch inside one
  # join looks like at the markup level, regardless of whether the button
  # markup is written inline or shared through a helper component (as in
  # `MydiaWeb.SegmentedControl`'s own private `segment/1`, whose single class
  # list applies `btn-primary` or `btn-ghost` conditionally on `@selected?`).
  defp ghost_segment?(path), do: path |> File.read!() |> offends?()

  defp offends?(content) do
    values = class_attribute_values(content)

    Enum.any?(values, &(&1 =~ "join-item" and &1 =~ "btn-ghost")) and
      Enum.any?(values, &(&1 =~ "join-item" and &1 =~ "btn-primary"))
  end

  defp class_attribute_values(content) do
    content
    |> class_attr_starts()
    |> Enum.map(&extract_class_value(content, &1))
  end

  # Byte offset right after each `class=` occurrence, i.e. where the value
  # (a `"` or a `{`) begins.
  defp class_attr_starts(content), do: class_attr_starts(content, 0, [])

  defp class_attr_starts(content, offset, acc) when offset <= byte_size(content) do
    case :binary.match(content, "class=", scope: {offset, byte_size(content) - offset}) do
      {start, len} -> class_attr_starts(content, start + len, [start + len | acc])
      :nomatch -> Enum.reverse(acc)
    end
  end

  defp extract_class_value(content, pos) when pos < byte_size(content) do
    case :binary.at(content, pos) do
      ?" -> extract_quoted(content, pos + 1)
      ?{ -> extract_braced(content, pos + 1, 1, pos + 1)
      _ -> ""
    end
  end

  defp extract_class_value(_content, _pos), do: ""

  # class="..." runs to the next literal quote.
  defp extract_quoted(content, start) do
    case :binary.match(content, "\"", scope: {start, byte_size(content) - start}) do
      {stop, _} -> binary_part(content, start, stop - start)
      :nomatch -> binary_part(content, start, byte_size(content) - start)
    end
  end

  # class={...} runs to the `}` that balances the opening `{`, counting
  # nested braces along the way (a `cond`/`if`, a map, string interpolation)
  # so any `>` inside never ends the scan early.
  defp extract_braced(content, pos, depth, value_start) when pos < byte_size(content) do
    case :binary.at(content, pos) do
      ?{ -> extract_braced(content, pos + 1, depth + 1, value_start)
      ?} when depth == 1 -> binary_part(content, value_start, pos - value_start)
      ?} -> extract_braced(content, pos + 1, depth - 1, value_start)
      _ -> extract_braced(content, pos + 1, depth, value_start)
    end
  end

  defp extract_braced(content, pos, _depth, value_start) do
    binary_part(content, value_start, pos - value_start)
  end
end
