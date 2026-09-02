defmodule MydiaWeb.PosterCardConsistencyTest do
  @moduledoc """
  Poster card titles were hand-copied across seven files and drifted, which is
  what `MydiaWeb.PosterCardComponents.poster_card_body/1` exists to stop. A
  copy that reappears looks correct in isolation and only shows up as a ragged
  row on a page nobody thought to open.

  This is the same kind of guard as
  `test/mydia/repo/migrations/no_varchar_columns_test.exs`.
  """

  use ExUnit.Case, async: true

  @source_glob "lib/mydia_web/**/*.{ex,heex}"

  # Matches a class attribute in either form: class="..." or class={...}
  @class_attr ~r/class=(?:"[^"]*"|\{[^}]*\})/

  test "the source glob actually matches files" do
    refute Path.wildcard(@source_glob) == []
  end

  test "no template hand-rolls a poster card title" do
    offenders =
      @source_glob
      |> Path.wildcard()
      |> Enum.filter(&hand_rolled_title?(File.read!(&1)))

    assert offenders == [],
           """
           These files hand-roll a poster card title instead of using
           MydiaWeb.PosterCardComponents.poster_card_body/1:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}

           A clamped title with no reserved height makes the row ragged. Use
           <.poster_card_body title={...}> and put the rest in its :meta slot.
           """
  end

  # Scoped to class attributes so this can't collide with prose that merely
  # discusses both class names (e.g. a moduledoc), and so it catches both
  # quoted classes and HEEx's `class={[...]}` list syntax regardless of the
  # order the two classes appear in.
  defp hand_rolled_title?(source) do
    @class_attr
    |> Regex.scan(source)
    |> Enum.any?(fn [attr] ->
      String.contains?(attr, "card-title") and String.contains?(attr, "line-clamp-2")
    end)
  end
end
