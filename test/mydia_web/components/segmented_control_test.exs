defmodule MydiaWeb.Components.SegmentedControlTest do
  @moduledoc """
  The contract every segmented control in the app depends on.

  These are markup assertions. They cannot see colour: the reason unselected
  segments carry no colour class is that `btn-ghost` computes to `alpha=0`,
  which measures 1.000 contrast against the page in dark mode. That number
  came from a browser and any change to the treatment needs the same. See
  docs/superpowers/specs/2026-09-01-segmented-control-design.md.
  """

  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import MydiaWeb.SegmentedControl

  defp plain(value) do
    assigns = %{value: value}

    rendered_to_string(~H"""
    <.segmented_control id="picker" value={@value} event="pick" param="choice" label="Pick one">
      <:option value="a" label="Alpha" />
      <:option value="b" label="Beta" />
    </.segmented_control>
    """)
  end

  defp sized(size) do
    assigns = %{size: size}

    rendered_to_string(~H"""
    <.segmented_control value="b" event="pick" param="choice" label="Pick one" size={@size}>
      <:option value="a" label="Alpha" />
      <:option value="b" label="Beta" />
    </.segmented_control>
    """)
  end

  defp atom_valued(value) do
    assigns = %{value: value}

    rendered_to_string(~H"""
    <.segmented_control value={@value} event="pick" param="choice" label="Pick one">
      <:option value={:movie} label="Movies" />
      <:option value={:tv_show} label="TV Shows" />
    </.segmented_control>
    """)
  end

  defp icon_only(value) do
    assigns = %{value: value}

    rendered_to_string(~H"""
    <.segmented_control value={@value} event="pick" param="choice" label="Pick one" icon_only>
      <:option value="a" label="Alpha" icon="hero-stop" />
      <:option value="b" label="Beta" icon="hero-table-cells" />
    </.segmented_control>
    """)
  end

  defp labelled_with_icons(value) do
    assigns = %{value: value}

    rendered_to_string(~H"""
    <.segmented_control value={@value} event="pick" param="choice" label="Pick one">
      <:option value="a" label="Alpha" icon="hero-film" />
      <:option value="b" label="Beta" icon="hero-tv" />
    </.segmented_control>
    """)
  end

  defp buttons(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.query("button")
  defp classes(html), do: html |> buttons() |> LazyHTML.attribute("class")
  defp attrs(html, name), do: html |> buttons() |> LazyHTML.attribute(name)

  test "the group is a labelled join carrying the given id" do
    join = plain("b") |> LazyHTML.from_fragment() |> LazyHTML.filter("div.join")

    assert LazyHTML.attribute(join, "id") == ["picker"]
    assert LazyHTML.attribute(join, "role") == ["group"]
    assert LazyHTML.attribute(join, "aria-label") == ["Pick one"]
  end

  test "options render in declaration order with the event and value binding" do
    html = plain("b")

    assert attrs(html, "phx-click") == ["pick", "pick"]
    assert attrs(html, "phx-value-choice") == ["a", "b"]
    assert html |> buttons() |> LazyHTML.text() =~ "Alpha"
    assert html |> buttons() |> LazyHTML.text() =~ "Beta"
  end

  test "the selected option is the only one marked btn-primary" do
    [first, second] = classes(plain("b"))

    refute first =~ "btn-primary"
    assert second =~ "btn-primary"
  end

  test "no option is ever btn-ghost" do
    for class <- classes(plain("b")) do
      refute class =~ "btn-ghost",
             "btn-ghost computes to alpha=0, leaving the segment with no body"
    end
  end

  test "unselected options carry the dark-mode hover override" do
    # daisyUI's own .btn:hover mixes toward black, which on a dark theme is
    # both imperceptible and the wrong direction.
    [first, second] = classes(plain("b"))

    assert first =~ "dark:hover:bg-base-300"
    refute second =~ "dark:hover:bg-base-300"
  end

  test "aria-pressed is the literal string on every button" do
    # HEEx renders aria-pressed={true} as a bare attribute and drops it
    # entirely for false, so the component must wrap it in to_string/1.
    assert attrs(plain("b"), "aria-pressed") == ["false", "true"]
  end

  test "an atom assign matches a string option value" do
    assert attrs(plain(:a), "aria-pressed") == ["true", "false"]
  end

  test "an atom option value serializes to a bare string in phx-value" do
    html = atom_valued(:movie)

    assert attrs(html, "phx-value-choice") == ["movie", "tv_show"]
    assert attrs(html, "aria-pressed") == ["true", "false"]
  end

  test "size defaults to btn-sm and md omits it" do
    for class <- classes(plain("b")), do: assert(class =~ "btn-sm")
    for class <- classes(sized("md")), do: refute(class =~ "btn-sm")
  end

  test "icon_only buttons are square, aria-named, and show no visible text" do
    html = icon_only("b")

    assert attrs(html, "aria-label") == ["Alpha", "Beta"]
    for class <- classes(html), do: assert(class =~ "btn-square")

    # Checked as text content, not as a raw substring: the labels still
    # appear in aria-label and data-tip on correct output.
    assert html |> buttons() |> LazyHTML.text() |> String.trim() == ""
  end

  test "each tooltip sits on a wrapper, and join-item stays on the button" do
    html = icon_only("b")
    wrappers = html |> LazyHTML.from_fragment() |> LazyHTML.query("div.tooltip")

    assert LazyHTML.attribute(wrappers, "data-tip") == ["Alpha", "Beta"]

    # daisyUI reveals the tip through `.tooltip:has(:focus-visible)`, and
    # `:has()` implies a descendant combinator, so a tooltip on the button
    # itself never fires for a keyboard user.
    refute Enum.any?(classes(html), &(&1 =~ "tooltip"))

    # `.join-item > *` resets the four --join-* radius variables to `initial`,
    # so a button inside a join-item wrapper computes every corner to 0 and
    # the filled active button spills square out of the join's rounded cap.
    for class <- LazyHTML.attribute(wrappers, "class"), do: refute(class =~ "join-item")
    for class <- classes(html), do: assert(class =~ "join-item")
  end

  test "labelled options render the icon beside visible text, with no tooltip" do
    html = labelled_with_icons("b")

    assert html |> buttons() |> LazyHTML.text() =~ "Alpha"

    # The visible text is already the accessible name, so aria-label would be
    # redundant and is deliberately absent.
    refute html =~ ~s(aria-label="Alpha")

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("span.hero-film") |> Enum.count() ==
             1

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("div.tooltip") |> Enum.empty?()
  end

  test "an option with no icon renders text only" do
    html = plain("b")

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("button > span") |> Enum.empty?()
    assert html |> buttons() |> LazyHTML.text() =~ "Alpha"
  end
end
