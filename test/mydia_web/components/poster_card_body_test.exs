defmodule MydiaWeb.PosterCardComponents.PosterCardBodyTest do
  @moduledoc """
  The reserved title height and the bottom pin are the assertions that matter.
  They are the two things that were hand-copied across seven files and drifted,
  and the only reason this component exists.
  """

  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import MydiaWeb.PosterCardComponents

  defp with_meta(title) do
    assigns = %{title: title}

    rendered_to_string(~H"""
    <.poster_card_body title={@title}>
      <:meta>
        <span class="text-xs">1994</span>
      </:meta>
    </.poster_card_body>
    """)
  end

  defp without_meta(title) do
    assigns = %{title: title}

    rendered_to_string(~H"""
    <.poster_card_body title={@title} />
    """)
  end

  test "reserves two lines for the title regardless of its length" do
    html = without_meta("Nine Winters")

    assert html =~ "line-clamp-2"
    assert html =~ "min-h-[2lh]"
  end

  test "carries the full title as a tooltip so a clamped title stays readable" do
    long = "The Cartographer's Dilemma: A Very Long Subtitle That Will Clamp"
    escaped = long |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    assert with_meta(long) =~ ~s(title="#{escaped}")
  end

  test "does not use daisyUI card-title, which fights line-clamp" do
    html = without_meta("Nine Winters")

    assert html =~ "font-semibold"
    refute html =~ "card-title"
  end

  test "pins the meta slot to the bottom of the card" do
    html = with_meta("Nine Winters")

    assert html =~ "mt-auto"
    assert html =~ "1994"
  end

  test "renders no meta wrapper when the slot is empty" do
    refute without_meta("Nine Winters") =~ "mt-auto"
  end

  test "keeps the card-body padding every call site uses" do
    html = without_meta("Nine Winters")

    assert html =~ "card-body"
    assert html =~ "p-3"
  end
end
