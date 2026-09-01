defmodule Mydia.Collections.SidebarIconSafelistTest do
  # Guards a cross-file invariant, in the spirit of
  # test/mydia/repo/migrations/no_varchar_columns_test.exs.
  #
  # Sidebar icons are chosen at runtime from collections.sidebar_icon, so the
  # class name never appears in anything Tailwind scans. The allowlist that
  # defines them lives in lib/mydia/, which is outside the @source globs in
  # app.css. An icon that is offered in the UI but absent from the safelist
  # gets no CSS and renders as a blank box, with no error anywhere.
  use ExUnit.Case, async: true

  alias Mydia.Collections.Collection

  @app_css "assets/css/app.css"

  test "every allowlisted sidebar icon is safelisted in app.css" do
    css = File.read!(@app_css)

    safelisted =
      case Regex.run(~r/@source inline\("hero-\{([^}]+)\}"\)/, css) do
        [_full, names] ->
          names
          |> String.split(",")
          |> Enum.map(&"hero-#{String.trim(&1)}")

        nil ->
          []
      end

    missing = Collection.valid_sidebar_icons() -- safelisted

    assert missing == [],
           """
           These sidebar icons are offered in the UI but never emitted by
           Tailwind, so they render as blank boxes: #{inspect(missing)}

           Add them to the @source inline("hero-{...}") safelist in #{@app_css}.
           """
  end
end
