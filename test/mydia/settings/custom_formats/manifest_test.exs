defmodule Mydia.Settings.CustomFormats.ManifestTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.CustomFormats.Manifest

  test "ships the six French language formats" do
    assert Enum.sort(Manifest.slugs()) == [
             "lang-multi",
             "lang-vf2",
             "lang-vff",
             "lang-vfi",
             "lang-vfq",
             "lang-vostfr"
           ]
  end

  test "every entry has a slug, name, description, and at least one pattern" do
    for entry <- Manifest.all() do
      assert is_binary(entry.slug) and entry.slug != ""
      assert is_binary(entry.name) and entry.name != ""
      assert is_binary(entry.description)
      assert is_list(entry.patterns) and entry.patterns != []
      assert Enum.all?(entry.patterns, &is_binary/1)
    end
  end

  test "every shipped pattern compiles" do
    for entry <- Manifest.all(), pattern <- entry.patterns do
      assert {:ok, _} = :re.compile(pattern, [:caseless, :unicode]),
             "#{entry.slug} has an uncompilable pattern: #{pattern}"
    end
  end

  test "get/1 returns an entry by slug and nil for an unknown one" do
    assert %{name: "VFF"} = Manifest.get("lang-vff")
    assert Manifest.get("nope") == nil
  end

  test "VFF covers TRUEFRENCH" do
    assert "\\bTRUEFRENCH\\b" in Manifest.get("lang-vff").patterns
  end
end
