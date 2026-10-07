defmodule MydiaWeb.PosterHoverClippingTest do
  @moduledoc """
  A poster rail hand-written as a bare `overflow-x-auto snap-x` scroller crops
  the `hover-3d` pop-out at its top and bottom edge (#1068).
  `MydiaWeb.PosterCardComponents.poster_rail/1` owns the padding that prevents
  it, so every rail goes through that component.

  The same kind of guard as `MydiaWeb.PosterCardConsistencyTest`.
  """

  use ExUnit.Case, async: true

  @source_glob "lib/mydia_web/**/*.{ex,heex}"
  @owner "lib/mydia_web/components/poster_card_components.ex"

  @class_attr ~r/class=(?:"[^"]*"|\{[^}]*\})/

  test "the source glob actually matches files" do
    refute Path.wildcard(@source_glob) == []
  end

  test "no template hand-rolls a poster rail scroller" do
    offenders =
      @source_glob
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @owner))
      |> Enum.filter(&hand_rolled_rail?(File.read!(&1)))

    assert offenders == [],
           """
           These files hand-roll a snapping horizontal scroller instead of using
           MydiaWeb.PosterCardComponents.poster_rail/1:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}

           Without poster_rail's padding the scroller crops the poster hover
           pop-out. Use <.poster_rail> and add any extra classes via its class attr.
           """
  end

  defp hand_rolled_rail?(source) do
    @class_attr
    |> Regex.scan(source)
    |> Enum.any?(fn [attr] ->
      String.contains?(attr, "overflow-x-auto") and String.contains?(attr, "snap-x")
    end)
  end
end
