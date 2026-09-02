defmodule MydiaWeb.PosterCardGridSkeletonTest do
  @moduledoc """
  The card count and the passed-through column class are what the call sites
  depend on. The internal bar shapes are asserted loosely on purpose: they are
  tuned against a measured real card in Task 4, and pinning exact heights here
  would turn that tuning into a test failure.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.DiscoverComponents

  defp render_skeleton(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{id: "grid-skeleton", columns: "grid-cols-2 lg:grid-cols-5"},
        overrides
      )

    render_component(&DiscoverComponents.poster_card_grid_skeleton/1, assigns)
    |> LazyHTML.from_fragment()
  end

  test "renders one placeholder card per count" do
    doc = render_skeleton(%{count: 7})

    assert doc |> LazyHTML.query("div.card") |> Enum.count() == 7
  end

  test "defaults to twenty cards, matching a provider page" do
    doc = render_skeleton()

    assert doc |> LazyHTML.query("div.card") |> Enum.count() == 20
  end

  test "applies the caller's column and gap classes to the grid" do
    doc = render_skeleton(%{columns: "grid-cols-4 xl:grid-cols-12", gap: "gap-3 md:gap-4"})

    [class] = doc |> LazyHTML.filter("#grid-skeleton") |> LazyHTML.attribute("class")

    assert class =~ "grid-cols-4"
    assert class =~ "xl:grid-cols-12"
    assert class =~ "gap-3"
    assert class =~ "md:gap-4"
  end

  test "announces itself as a loading region" do
    doc = render_skeleton(%{count: 1})

    [role] = doc |> LazyHTML.filter("#grid-skeleton") |> LazyHTML.attribute("role")
    [label] = doc |> LazyHTML.filter("#grid-skeleton") |> LazyHTML.attribute("aria-label")

    assert role == "status"
    assert label == "Loading titles"
  end

  # daisyUI's .skeleton sets border-radius on all four corners. The real
  # poster_figure gets rounded-t-box from card_poster, so without the override
  # the placeholder poster rounds its bottom corners inside the card.
  test "the poster placeholder squares off its bottom corners" do
    doc = render_skeleton(%{count: 1})

    [class] =
      doc
      |> LazyHTML.query("div.card > div.skeleton")
      |> LazyHTML.attribute("class")

    assert class =~ "aspect-[2/3]"
    assert class =~ "rounded-t-box"
    assert class =~ "rounded-b-none"
  end

  test "each card carries a body with placeholder bars" do
    doc = render_skeleton(%{count: 3})

    assert doc |> LazyHTML.query("div.card > div.card-body") |> Enum.count() == 3
    refute doc |> LazyHTML.query("div.card-body div.skeleton") |> Enum.empty?()
  end
end
