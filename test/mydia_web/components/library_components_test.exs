defmodule MydiaWeb.LibraryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.LibraryComponents

  # Libraries have no name column, only a path, which is why the menu shows a
  # basename with the full path underneath.
  defp libraries(count) do
    for i <- 1..count, do: %{id: "lib-#{i}", path: "/media/movies-#{i}"}
  end

  defp picker(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{libraries: libraries(2), event: "add_to_library"},
        overrides
      )

    render_component(&LibraryComponents.library_picker_menu/1, assigns)
  end

  describe "library_picker_menu/1" do
    test "renders nothing when there is only one candidate library" do
      html = picker(%{libraries: libraries(1)})

      refute html =~ "library-picker-caret"
    end

    test "renders a caret and one entry per library when there are several" do
      html = picker()

      assert html =~ ~s(data-test="library-picker-caret")
      assert html =~ "movies-1"
      assert html =~ "movies-2"
    end

    # Regression for #465: the menu sat at z-[1] while the trending card's
    # rating and in-library badges sit at z-10, so even the unclipped sliver
    # rendered underneath them.
    test "the menu stacks above the trending card badges" do
      html = picker()

      assert html =~ "z-20"
      refute html =~ "z-[1]"
    end

    test "opens downward by default" do
      refute picker() =~ "dropdown-top"
    end

    test "opens upward when placement is :top" do
      assert picker(%{placement: :top}) =~ "dropdown-top"
    end
  end
end
