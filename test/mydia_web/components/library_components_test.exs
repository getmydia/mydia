defmodule MydiaWeb.LibraryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.LibraryComponents

  # Libraries have no name column, only a path, which is why the menu shows a
  # basename with the full path underneath.
  defp libraries(count) do
    for i <- 1..count, do: %{id: "lib-#{i}", path: "/media/movies-#{i}"}
  end

  defp picker_button(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          libraries: libraries(2),
          tmdb_id: "693134",
          media_type: :movie,
          title: "Dune: Part Two"
        },
        overrides
      )

    render_component(&LibraryComponents.library_picker_button/1, assigns)
  end

  defp picker_dialog(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          picker: %{
            tmdb_id: "693134",
            media_type: :movie,
            title: "Dune: Part Two",
            libraries: libraries(2)
          }
        },
        overrides
      )

    render_component(&LibraryComponents.library_picker_dialog/1, assigns)
  end

  describe "library_picker_button/1" do
    test "renders nothing when there is only one candidate library" do
      refute picker_button(%{libraries: libraries(1)}) =~ "library-picker-caret"
    end

    test "renders a real button that opens the dialog, carrying the card's identity" do
      html = picker_button()
      document = LazyHTML.from_fragment(html)

      caret = LazyHTML.query(document, ~s(button[data-test="library-picker-caret"]))

      assert LazyHTML.attribute(caret, "phx-click") == ["open_library_picker"]
      assert LazyHTML.attribute(caret, "phx-value-tmdb_id") == ["693134"]
      assert LazyHTML.attribute(caret, "phx-value-media_type") == ["movie"]
      assert LazyHTML.attribute(caret, "phx-value-title") == ["Dune: Part Two"]
    end
  end

  describe "library_picker_dialog/1" do
    test "renders a closed dialog when no picker is open" do
      html = render_component(&LibraryComponents.library_picker_dialog/1, %{picker: nil})
      document = LazyHTML.from_fragment(html)

      dialog = LazyHTML.filter(document, "dialog")

      # Guard the cardinality first: `LazyHTML.attribute/2` on a zero-node
      # match returns `[]` same as a genuinely closed dialog's missing `open`
      # attribute, so without this the assertion below would pass even if the
      # "dialog" selector matched nothing at all.
      assert Enum.count(dialog) == 1
      assert LazyHTML.attribute(dialog, "open") == []
      refute html =~ "library-picker-option"
    end

    # The dialog is a page-level overlay rather than a card descendant, which
    # is the whole point: the sidebar is z-40 and the mobile dock is z-50, so
    # no value a card can claim keeps the old anchored menu visible. daisyUI's
    # .modal is z-999 and the picker takes 1000 so it also wins against the
    # trending detail modal without depending on DOM order.
    test "the open dialog sits above every other layer" do
      document = LazyHTML.from_fragment(picker_dialog())

      dialog = LazyHTML.filter(document, "dialog")
      [class] = LazyHTML.attribute(dialog, "class")

      assert LazyHTML.attribute(dialog, "open") == [""]
      assert class =~ "modal"
      assert class =~ "z-[1000]"
    end

    test "lists every candidate library with the values the add handler needs" do
      document = LazyHTML.from_fragment(picker_dialog())

      options = LazyHTML.query(document, ~s(button[data-test="library-picker-option"]))

      assert LazyHTML.attribute(options, "phx-click") == ["add_to_library", "add_to_library"]
      assert LazyHTML.attribute(options, "phx-value-library_path_id") == ["lib-1", "lib-2"]
      assert LazyHTML.attribute(options, "phx-value-tmdb_id") == ["693134", "693134"]
      assert LazyHTML.attribute(options, "phx-value-media_type") == ["movie", "movie"]
    end

    test "shows the basename with the full path underneath" do
      html = picker_dialog()

      assert html =~ "movies-1"
      assert html =~ "/media/movies-1"
    end

    test "names the title being added" do
      assert picker_dialog() =~ "Dune: Part Two"
    end

    test "offers cancel and a backdrop that both close the dialog" do
      document = LazyHTML.from_fragment(picker_dialog())

      closers = LazyHTML.query(document, ~s([phx-click="close_library_picker"]))

      assert Enum.count(closers) >= 2
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

    test "each tooltip sits on a wrapper around the button, not on the button" do
      html = render_component(&LibraryComponents.view_mode_toggle/1, view_mode: :grid)
      document = LazyHTML.from_fragment(html)

      # daisyUI reveals the tip through `.tooltip:has(:focus-visible)`, and
      # `:has()` implies a descendant combinator, so a `.tooltip` on the button
      # only matches when something inside it is focused. The button's only
      # child is the non-focusable span from icon/1, which would leave a
      # keyboard user tabbing onto an unlabelled icon.
      wrappers = LazyHTML.query(document, "div.tooltip")

      assert LazyHTML.attribute(wrappers, "data-tip") == ["Grid", "List"]

      # join-item belongs on the button, never on the wrapper: daisyUI's
      # `.join-item > *` resets the --join-* radius variables to `initial`, so
      # a nested button computes every corner to 0 and the filled active button
      # spills square out of the join's rounded end cap.
      for class <- LazyHTML.attribute(wrappers, "class") do
        refute class =~ "join-item"
      end

      for class <- document |> LazyHTML.query("button") |> LazyHTML.attribute("class") do
        assert class =~ "join-item"
      end

      refute document
             |> LazyHTML.query("button")
             |> LazyHTML.attribute("class")
             |> Enum.any?(&(&1 =~ "tooltip"))
    end

    test "the buttons are square icon buttons and the join is a labelled group" do
      html = render_component(&LibraryComponents.view_mode_toggle/1, view_mode: :grid)
      document = LazyHTML.from_fragment(html)

      # btn-square keeps a label-less button from collapsing to its icon.
      for class <- document |> LazyHTML.query("button") |> LazyHTML.attribute("class") do
        assert class =~ "btn-square"
      end

      # Without visible labels the two buttons need to announce as one control.
      join = LazyHTML.filter(document, "div.join")

      assert LazyHTML.attribute(join, "role") == ["group"]
      assert LazyHTML.attribute(join, "aria-label") == ["View mode"]
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
