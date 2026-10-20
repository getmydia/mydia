defmodule MydiaWeb.ThemesCssParityTest do
  @moduledoc """
  Every theme in `Mydia.Accounts.Themes` must have CSS, and every theme the
  CSS ships must be in the catalogue. Reads the CSS sources, not the built
  bundle, so it runs without an asset build.
  """
  use ExUnit.Case, async: true

  alias Mydia.Accounts.Themes

  @css_dir Path.expand("../../assets/css", __DIR__)

  test "catalogue ids match the themes the CSS defines" do
    assert MapSet.new(Enum.map(Themes.all(), & &1.id)) == css_theme_ids()
  end

  test "every radius preset has a data-radius rule" do
    for id <- Themes.radii(), id != "theme" do
      assert app_css() =~ ~s(:root[data-radius="#{id}"]), "no CSS rule for radius #{id}"
    end
  end

  defp css_theme_ids do
    MapSet.new(mydia_ids() ++ daisyui_ids() ++ catppuccin_ids())
  end

  defp mydia_ids do
    ~r/\[data-theme="([^"]+)"\]/
    |> Regex.scan(File.read!(Path.join(@css_dir, "mydiaTheme.ts")), capture: :all_but_first)
    |> List.flatten()
  end

  defp daisyui_ids do
    [_, list] = Regex.run(~r/@plugin "daisyui" \{\s*themes:\s*([^;]+);/, app_css())

    list
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.split() |> hd()))
  end

  defp catppuccin_ids do
    ~r/@plugin "\.\/catppuccinTheme\.(\w+)\.ts"/
    |> Regex.scan(app_css(), capture: :all_but_first)
    |> List.flatten()
  end

  defp app_css, do: File.read!(Path.join(@css_dir, "app.css"))
end
