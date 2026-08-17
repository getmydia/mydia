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
    #
    # daisyUI's `.join > :where(:focus, :has(:focus))` rule stamps z-index: 1
    # on the `.dropdown` wrapper the moment the caret is focused (the same
    # condition that opens the menu), which creates a stacking context on
    # that `position: relative` div. A z-index on the inner `<ul>` is then
    # confined below that context regardless of its value, so the wrapper
    # itself must carry the z-index, not the menu list.
    test "the menu stacks above the trending card badges" do
      html = picker()
      document = LazyHTML.from_fragment(html)

      # The `.dropdown` div is the root node of this component's output, so
      # filter/2 (root nodes only) is correct here.
      wrapper_class =
        document
        |> LazyHTML.filter("div.dropdown")
        |> LazyHTML.attribute("class")
        |> List.first()

      assert wrapper_class =~ "z-20"

      # The `<ul>` is nested inside the wrapper, so it needs query/2, not
      # filter/2, to be found at all.
      menu_class =
        document
        |> LazyHTML.query("ul.dropdown-content")
        |> LazyHTML.attribute("class")
        |> List.first()

      refute menu_class =~ "z-20"
    end

    test "opens downward by default" do
      refute picker() =~ "dropdown-top"
    end

    test "opens upward when placement is :top" do
      assert picker(%{placement: :top}) =~ "dropdown-top"
    end
  end

  describe "view_mode_toggle/1" do
    test "renders two icon-only buttons with accessible names and pressed state" do
      html = render_component(&LibraryComponents.view_mode_toggle/1, view_mode: :grid)

      buttons =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")

      assert LazyHTML.attribute(buttons, "aria-label") == ["Grid", "List"]

      # Literal strings, not bare attributes. HEEx drops aria-pressed={false}
      # entirely, so the component wraps the comparison in to_string/1.
      assert LazyHTML.attribute(buttons, "aria-pressed") == ["true", "false"]

      # The mode bindings the LiveViews dispatch on must survive the relabel.
      assert LazyHTML.attribute(buttons, "phx-value-mode") == ["grid", "list"]
    end

    test "the buttons render no visible text label" do
      html = render_component(&LibraryComponents.view_mode_toggle/1, view_mode: :list)

      # Checked as text content: "Grid" and "List" still appear in aria-label
      # and data-tip, so a raw substring refute would fail on correct output.
      text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")
        |> LazyHTML.text()
        |> String.trim()

      assert text == ""
    end

    test "the active mode is the one marked btn-primary" do
      html = render_component(&LibraryComponents.view_mode_toggle/1, view_mode: :list)

      classes =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")
        |> LazyHTML.attribute("class")

      refute Enum.at(classes, 0) =~ "btn-primary"
      assert Enum.at(classes, 1) =~ "btn-primary"
    end
  end
end
