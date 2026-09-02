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

  test "the sidebar icon allowlist and the app.css safelist agree exactly" do
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

    expected = Collection.valid_sidebar_icons()
    missing = expected -- safelisted
    stale = safelisted -- expected

    assert missing == [] and stale == [],
           """
           The sidebar icon allowlist and the #{@app_css} safelist have drifted.

           Offered in the UI but never emitted by Tailwind, so they render as
           blank boxes: #{inspect(missing)}

           Safelisted but no longer offered, so the safelist is carrying dead
           entries: #{inspect(stale)}

           The allowlist is @sidebar_icons in lib/mydia/collections/collection.ex;
           the safelist is the @source inline("hero-{...}") line in #{@app_css}.
           """
  end
end
