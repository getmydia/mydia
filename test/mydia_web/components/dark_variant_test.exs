defmodule MydiaWeb.Components.DarkVariantTest do
  @moduledoc """
  Tailwind's `dark:` variant is declared by hand in app.css. It was originally
  written against `[data-theme=dark]`, but the application sets `mydia-dark`
  (see `root.html.heex`), so the variant matched no element that exists and
  every `dark:` utility silently produced nothing.

  Nothing errors when this regresses. An unmatched variant compiles fine and
  emits CSS that can never apply, so only this test catches it.
  """

  use ExUnit.Case, async: true

  @app_css Path.expand("../../../assets/css/app.css", __DIR__)

  test "the dark variant targets the theme name the application actually sets" do
    css = File.read!(@app_css)

    assert css =~ ~s(@custom-variant dark),
           "app.css no longer declares a `dark:` custom variant"

    variant_line =
      css
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "@custom-variant dark"))

    assert variant_line =~ "data-theme=mydia-dark",
           """
           The `dark:` variant must target `mydia-dark`, the value
           root.html.heex actually writes to data-theme. Got:

             #{variant_line}
           """

    refute variant_line =~ "data-theme=dark]",
           "The variant still matches the non-existent bare `dark` theme"
  end

  test "root.html.heex still sets the theme name the variant expects" do
    root =
      Path.expand("../../../lib/mydia_web/components/layouts/root.html.heex", __DIR__)
      |> File.read!()

    assert root =~ "'mydia-dark'",
           "root.html.heex no longer sets mydia-dark; the dark variant needs updating too"
  end
end
