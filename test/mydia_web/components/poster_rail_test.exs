defmodule MydiaWeb.PosterRailTest do
  @moduledoc """
  A horizontal scroller clips vertically too: when one overflow axis is not
  `visible`, a `visible` value on the other computes to `auto`. The rail
  therefore pads itself on every side so `hover-3d` posters have room to pop
  out, and cancels that padding with negative margins so the layout does not
  move (#1068).
  """

  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import MydiaWeb.PosterCardComponents

  defp scroller_classes(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("class")
    |> List.first()
    |> String.split()
  end

  test "pads every side for the pop-out and cancels it in the layout" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.poster_rail id="rail">
        <div class="w-36">card</div>
      </.poster_rail>
      """)

    classes = scroller_classes(html)

    for class <-
          ~w(flex gap-3 overflow-x-auto snap-x scroll-smooth scroll-px-3 p-3 -mx-3 -mt-3 -mb-1) do
      assert class in classes, "missing #{class} in #{inspect(classes)}"
    end

    refute "pb-2" in classes
    assert html =~ ~s(id="rail")
    assert html =~ "card"
  end

  test "appends caller classes and passes global attributes through" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.poster_rail class="items-start" role="status" aria-label="Loading titles">x</.poster_rail>
      """)

    assert "items-start" in scroller_classes(html)
    assert html =~ ~s(role="status")
    assert html =~ ~s(aria-label="Loading titles")
  end
end
