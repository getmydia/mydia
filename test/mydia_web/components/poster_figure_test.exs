defmodule MydiaWeb.CoreComponents.PosterFigureTest do
  @moduledoc """
  The hover structure is the assertion that matters. It is the behavior that
  was hand-copied across eight files and drifted, and the reason this component
  exists.
  """

  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import MydiaWeb.CoreComponents

  test "renders the poster with DaisyUI's 3D hover structure" do
    html =
      render_component(&poster_figure/1, src: "/p.jpg", alt: "Aftersun")

    assert html =~ ~s(src="/p.jpg")
    assert html =~ ~s(alt="Aftersun")
    assert html =~ "aspect-[2/3]"

    fragment = LazyHTML.from_fragment(html)
    hover_3d = LazyHTML.query(fragment, ".hover-3d")

    assert Enum.count(hover_3d) == 1
    assert fragment |> LazyHTML.query(".hover-3d > figure") |> Enum.count() == 1
    assert fragment |> LazyHTML.query(".hover-3d > div") |> Enum.count() == 8
    refute html =~ "group-hover:scale-105"
  end

  test "lazy loads by default" do
    html = render_component(&poster_figure/1, src: "/p.jpg", alt: "A")

    assert html =~ ~s(loading="lazy")
  end

  test "renders no loading attribute when loading is nil" do
    html = render_component(&poster_figure/1, src: "/p.jpg", alt: "A", loading: nil)

    refute html =~ "loading="
  end

  test "renders the fallback icon instead of an img when src is nil" do
    html = render_component(&poster_figure/1, src: nil, alt: "A", fallback_icon: "hero-tv")

    refute html =~ "<img"
    assert html =~ "hero-tv"
  end

  # The fallback shipped outside the shared hover structure at first, so a
  # grid mixing poster-less cards with poster-bearing ones lifted only some of
  # them. Pinned here because nothing else would catch it coming back.
  test "the fallback lives inside the same 3D hover structure as the poster" do
    html = render_component(&poster_figure/1, src: nil, alt: "A")
    fragment = LazyHTML.from_fragment(html)

    assert fragment |> LazyHTML.query(".hover-3d > figure") |> Enum.count() == 1
    assert fragment |> LazyHTML.query(".hover-3d > div") |> Enum.count() == 8
  end

  test "appends caller classes to the figure" do
    html = render_component(&poster_figure/1, src: "/p.jpg", alt: "A", class: "rounded-t-box")

    assert html =~ "rounded-t-box"
  end

  test "renders overlay slot content inside the figure" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <MydiaWeb.CoreComponents.poster_figure src="/p.jpg" alt="A">
        <:overlay><span id="badge">99</span></:overlay>
      </MydiaWeb.CoreComponents.poster_figure>
      """)

    assert html =~ ~s(id="badge")
  end
end
