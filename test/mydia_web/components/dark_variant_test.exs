defmodule MydiaWeb.Components.DarkVariantTest do
  @moduledoc """
  Tailwind's `dark:` variant is declared by hand in app.css and keys on
  `<html data-color-scheme="dark">`, not on a theme name: nine themes are dark,
  and a variant tied to one name silently skips the rest.

  Nothing errors when this regresses. An unmatched variant compiles fine and
  emits CSS that can never apply, so only this test catches it. The contract
  has two halves: the variant selector, and `theme_html_attrs/1` emitting the
  attribute for fixed modes (system mode leaves it to the inline script and
  `applySelection`, like `data-theme`).
  """

  use ExUnit.Case, async: true

  alias Mydia.Accounts.Themes
  alias MydiaWeb.Layouts

  @app_css Path.expand("../../../assets/css/app.css", __DIR__)

  test "the dark variant keys on data-color-scheme" do
    variant_line =
      @app_css
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "@custom-variant dark"))

    assert variant_line, "app.css no longer declares a `dark:` custom variant"
    assert variant_line =~ "[data-color-scheme=dark]"
    refute variant_line =~ "data-theme", "the variant must not name a single theme"
  end

  test "a fixed dark mode with a non-Mydia theme emits data-color-scheme=dark" do
    attrs = Layouts.theme_html_attrs(Themes.selection("dark", nil, "dracula", nil))

    assert attrs[:"data-theme"] == "dracula"
    assert attrs[:"data-color-scheme"] == "dark"
  end

  test "a fixed light mode emits data-color-scheme=light" do
    attrs = Layouts.theme_html_attrs(Themes.selection("light", "nord", nil, nil))

    assert attrs[:"data-color-scheme"] == "light"
  end

  test "system mode leaves the scheme to the browser" do
    attrs = Layouts.theme_html_attrs(Themes.selection("system", nil, nil, nil))

    assert attrs[:"data-color-scheme"] == nil
  end

  test "a radius preset emits data-radius; the theme's own corners omit it" do
    for radius <- Themes.radii() -- ["theme"] do
      attrs = Layouts.theme_html_attrs(Themes.selection("dark", nil, nil, radius))
      assert attrs[:"data-radius"] == radius
    end

    assert Layouts.theme_html_attrs(Themes.selection("dark", nil, nil, "theme"))[:"data-radius"] ==
             nil

    assert Layouts.theme_html_attrs(nil)[:"data-radius"] == nil
  end
end
