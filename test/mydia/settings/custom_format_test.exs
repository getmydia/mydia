defmodule Mydia.Settings.CustomFormatTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.CustomFormat
  alias Mydia.Settings.QualityProfileCustomFormat

  describe "CustomFormat.changeset/2" do
    test "accepts a valid format" do
      changeset =
        CustomFormat.changeset(%CustomFormat{}, %{
          slug: "my-format",
          name: "My Format",
          patterns: ["\\bVFF\\b"]
        })

      assert changeset.valid?
    end

    test "requires a name and at least one pattern" do
      changeset = CustomFormat.changeset(%CustomFormat{}, %{slug: "x", name: "X", patterns: []})
      refute changeset.valid?
      assert %{patterns: _} = errors_on(changeset)
    end

    test "rejects an uncompilable pattern with a readable message" do
      changeset =
        CustomFormat.changeset(%CustomFormat{}, %{
          slug: "bad",
          name: "Bad",
          patterns: ["(unclosed"]
        })

      refute changeset.valid?
      assert [message] = errors_on(changeset).patterns
      assert message =~ "parenthesis"
    end

    test "rejects a pattern longer than 500 characters" do
      changeset =
        CustomFormat.changeset(%CustomFormat{}, %{
          slug: "long",
          name: "Long",
          patterns: [String.duplicate("a", 501)]
        })

      refute changeset.valid?
    end

    test "rejects more than 20 patterns" do
      changeset =
        CustomFormat.changeset(%CustomFormat{}, %{
          slug: "many",
          name: "Many",
          patterns: Enum.map(1..21, &"pattern#{&1}")
        })

      refute changeset.valid?
    end

    test "slugify/1 produces a url-safe slug" do
      assert CustomFormat.slugify("My Format!") == "my-format"
      assert CustomFormat.slugify("  Spaces  Everywhere  ") == "spaces-everywhere"
      assert CustomFormat.slugify("VF2") == "vf2"
    end
  end

  describe "QualityProfileCustomFormat.changeset/2" do
    test "accepts a score assignment" do
      changeset =
        QualityProfileCustomFormat.changeset(%QualityProfileCustomFormat{}, %{
          quality_profile_id: Ecto.UUID.generate(),
          format_slug: "lang-vff",
          score: 100,
          reject: false
        })

      assert changeset.valid?
    end

    test "rejects a score outside the supported range" do
      changeset =
        QualityProfileCustomFormat.changeset(%QualityProfileCustomFormat{}, %{
          quality_profile_id: Ecto.UUID.generate(),
          format_slug: "lang-vff",
          score: 100_000
        })

      refute changeset.valid?
    end
  end
end
