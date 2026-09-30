defmodule Mydia.Plugins.PageIconSafelistTest do
  # A plugin page icon is chosen at runtime from a manifest, so Tailwind never
  # sees the class name, and manifest.ex is outside the @source globs in
  # app.css. An icon that is accepted but not safelisted renders as a blank box.
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Manifest

  @app_css "assets/css/app.css"

  test "the page icon allowlist and the app.css safelist agree exactly" do
    safelisted =
      ~r/@source inline\("hero-\{([^}]+)\}"\)/
      |> Regex.scan(File.read!(@app_css), capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&"hero-#{String.trim(&1)}")
      |> MapSet.new()

    missing = Enum.reject(Manifest.page_icons(), &MapSet.member?(safelisted, &1))

    assert missing == [],
           "page icons accepted by the manifest but not safelisted in #{@app_css}: " <>
             inspect(missing)

    # The page icons are safelisted as their own line, so a name removed from
    # the allowlist must not linger there.
    own_line =
      ~r/@source inline\("hero-\{([^}]+)\}"\)/
      |> Regex.scan(File.read!(@app_css), capture: :all_but_first)
      |> List.flatten()
      |> List.last()
      |> String.split(",")
      |> Enum.map(&"hero-#{String.trim(&1)}")

    assert own_line -- Manifest.page_icons() == []
  end
end
