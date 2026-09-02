defmodule MydiaWeb.LibraryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.LibraryComponents

  defp render_button(assigns) do
    render_component(&LibraryComponents.library_picker_button/1, assigns)
  end

  describe "library_picker_button/1" do
    # The caret no longer takes a `libraries` attr at all, so there is nothing
    # left to gate on and one unconditional-render test covers every install
    # size. The zero-and-one-library cases that used to be hidden are asserted
    # end to end in the feature test instead, where a real library count exists.
    test "always renders the caret" do
      html = render_button(%{tmdb_id: "551", media_type: "movie", title: "The Kestrel Protocol"})

      refute LazyHTML.from_fragment(html)
             |> LazyHTML.query(~s([data-test="add-config-caret"]))
             |> Enum.empty?()
    end

    test "pushes open_add_config with the card's identifiers" do
      html = render_button(%{tmdb_id: "551", media_type: "movie", title: "The Kestrel Protocol"})

      caret =
        LazyHTML.from_fragment(html) |> LazyHTML.query(~s([data-test="add-config-caret"]))

      assert LazyHTML.attribute(caret, "phx-click") == ["open_add_config"]
      assert LazyHTML.attribute(caret, "phx-value-tmdb_id") == ["551"]
      assert LazyHTML.attribute(caret, "phx-value-media_type") == ["movie"]
      assert LazyHTML.attribute(caret, "phx-value-title") == ["The Kestrel Protocol"]
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
