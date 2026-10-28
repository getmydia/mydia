defmodule Mydia.Accounts.ThemesTest do
  use ExUnit.Case, async: true

  alias Mydia.Accounts.Themes
  alias Mydia.Accounts.Themes.{Selection, Theme}

  test "ids are unique and every theme is light or dark" do
    ids = Enum.map(Themes.all(), & &1.id)
    assert ids == Enum.uniq(ids)
    assert Enum.all?(Themes.all(), &(&1.scheme in [:light, :dark]))
    assert Enum.all?(Themes.all(), &(&1.base =~ ~r/^#[0-9a-f]{6}$/))
  end

  test "light/0 and dark/0 partition the catalogue" do
    assert Enum.all?(Themes.light(), &(&1.scheme == :light))
    assert Enum.all?(Themes.dark(), &(&1.scheme == :dark))
    assert length(Themes.light()) + length(Themes.dark()) == length(Themes.all())
  end

  test "defaults are the Mydia pair" do
    assert %Theme{id: "mydia-light", scheme: :light} = Themes.default(:light)
    assert %Theme{id: "mydia-dark", scheme: :dark} = Themes.default(:dark)

    assert %Selection{mode: "system", light: %{id: "mydia-light"}, dark: %{id: "mydia-dark"}} =
             Themes.default_selection()
  end

  test "get/2 only returns a theme of the asked scheme" do
    assert %Theme{id: "dracula"} = Themes.get("dracula", :dark)
    assert Themes.get("dracula", :light) == nil
    assert Themes.get("nope", :dark) == nil
    assert Themes.get(nil) == nil
    refute Themes.valid_id?("dracula", :light)
    assert Themes.valid_id?("nord", :light)
  end

  test "radii/0 lists the theme's own corners first, then the presets" do
    assert Themes.radii() == ~w(theme sharp soft round)
  end

  test "selection/4 falls back per field" do
    s = Themes.selection("dark", "nord", "dracula", "sharp")

    assert %Selection{mode: "dark", light: %{id: "nord"}, dark: %{id: "dracula"}, radius: "sharp"} =
             s

    s = Themes.selection("bogus", "dracula", "retired-theme", "pointy")
    assert s.mode == "system"
    assert s.light.id == "mydia-light"
    assert s.dark.id == "mydia-dark"
    assert s.radius == "theme"

    assert Themes.selection(nil, nil, nil, nil) == Themes.default_selection()
  end

  test "selection/4 keeps every listed radius and drops the rest on its own" do
    for radius <- Themes.radii() do
      assert Themes.selection("dark", "nord", "dim", radius).radius == radius
    end

    for bad <- [nil, "square", "", 3, :sharp] do
      s = Themes.selection("dark", "nord", "dim", bad)
      assert s.radius == "theme"
      assert s.mode == "dark"
      assert s.light.id == "nord"
      assert s.dark.id == "dim"
    end
  end

  test "active/1 picks the slot for fixed modes and nil for system" do
    assert Themes.active(Themes.selection("light", "nord", "dim", nil)).id == "nord"
    assert Themes.active(Themes.selection("dark", "nord", "dim", nil)).id == "dim"
    assert Themes.active(Themes.selection("system", "nord", "dim", nil)) == nil
  end

  test "the zinc pair is listed last in each scheme" do
    assert %Theme{label: "Zinc Light", base: "#ffffff"} = List.last(Themes.light())
    assert %Theme{label: "Zinc Dark", base: "#09090b"} = List.last(Themes.dark())
  end

  test "to_client/1 is the push_event payload" do
    assert Themes.to_client(Themes.selection("dark", "nord", "dim", "soft")) == %{
             mode: "dark",
             radius: "soft",
             light_theme: "nord",
             dark_theme: "dim",
             light_base: Themes.get("nord").base,
             dark_base: Themes.get("dim").base
           }
  end
end
